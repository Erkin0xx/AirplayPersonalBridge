// Sortie audio virtuelle « AirPlay Personal Bridge » : un AudioServerPlugIn qui se présente comme une
// sortie 48 kHz stéréo float32, jette tout ce qu'on lui envoie, et annonce dans
// `kAudioDevicePropertyLatency` le retard réel de la diffusion vers les enceintes.
//
// Pourquoi : les lecteurs vidéo (Chromium, donc Dia) retardent l'image de la latence annoncée par la
// sortie audio. Sur les haut-parleurs du Mac, ils lisent 17 ms et l'image part ~2,3 s avant le son des
// enceintes. Un agrégat ne sait pas annoncer cette latence (il la range dans le safety offset, que
// Chromium ignore) : voir « Retard de bout en bout et vidéo » dans CLAUDE.md et l'ADR 014.
//
// Rien de ce qui part sur le fil ne dépend de ce pilote : il ne change que ce que les applications
// croient. L'audio réel est capté par le Process Tap de l'app, en amont du périphérique.
//
// Écrit d'après la documentation d'Apple (AudioServerPlugIn.h et l'exemple « Creating an Audio Server
// Driver Plug-in »), sans rien reprendre de BlackHole (GPL).
//
// Temps réel (CDC section 12 et 13) : les fonctions d'IO (GetZeroTimeStamp, WillDoIOOperation,
// BeginIOOperation, DoIOOperation, EndIOOperation) n'allouent rien, ne prennent aucun verrou et ne
// journalisent rien. L'horloge s'y calcule à partir d'une seule ancre atomique. Le verrou `gState`
// ne protège que les propriétés, lues et écrites hors du chemin d'IO.

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <os/log.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stddef.h>
#include <string.h>
#include <math.h>

// --- Constantes publiques : partagées avec l'app (Sources/AudioCore/VirtualOutputDevice.swift) ---

#define kAPB_DeviceUID   "fr.baptiste.airplaypersonalbridge.output"
#define kAPB_ModelUID    "fr.baptiste.airplaypersonalbridge.output.model"
#define kAPB_DeviceName  "AirPlay Personal Bridge"
#define kAPB_Manufacturer "AirPlay Personal Bridge"

// Propriété personnalisée du périphérique : la latence annoncée, en trames à 48 kHz, sous forme de
// CFNumber. Lue et écrite par l'app ou le CLI ; la valeur survit aux relances de coreaudiod grâce au
// stockage que l'hôte met à disposition (le plug-in, dans le bac à sable de coreaudiod, ne lit aucun
// fichier de l'utilisateur).
#define kAPB_PropertyLatencyFrames 'apbL'

// --- Constantes internes ---

enum {
    kObjectID_PlugIn = kAudioObjectPlugInObject,
    kObjectID_Device = 2,
    kObjectID_Stream = 3,
    kObjectID_Volume = 4,
    kObjectID_Mute = 5,
};

static const Float64 kSampleRate = 48000.0;
static const UInt32 kChannelCount = 2;
static const UInt32 kBytesPerFrame = sizeof(Float32) * 2;
// Période des horodatages zéro : l'hôte en déduit le rythme de l'horloge. Valeur de l'exemple d'Apple.
static const UInt32 kZeroTimeStampPeriod = 16384;
// Chromium borne la latence à 10 s : inutile d'accepter davantage.
static const UInt32 kMaxLatencyFrames = 480000;
// Plage du volume, en dB. Le pilote jette l'audio : elle ne sert qu'à l'affichage.
static const Float32 kVolumeMinDB = -64.0f;
static const Float32 kVolumeMaxDB = 0.0f;

#define kStorageKeyLatency CFSTR("latencyFrames")
#define kStorageKeyVolume  CFSTR("volumeScalar")
#define kStorageKeyMute    CFSTR("mute")

// --- État ---

static os_log_t gLog;
static AudioServerPlugInHostRef gHost = NULL;
static _Atomic UInt32 gRefCount = 0;

static pthread_mutex_t gState = PTHREAD_MUTEX_INITIALIZER;
static UInt32 gLatencyFrames = 0;   // sous gState
static Float32 gVolumeScalar = 1.0f; // sous gState
static bool gMute = false;          // sous gState
static UInt32 gIOClientCount = 0;   // sous gState

// Lues par le chemin d'IO : écrites seulement quand aucune IO ne tourne (StartIO du premier client,
// Initialize), d'où un simple accès atomique.
static _Atomic UInt64 gAnchorHostTime = 0;
static Float64 gHostTicksPerFrame = 0;

// --- Utilitaires ---

static Float32 scalarToDB(Float32 scalar) {
    if (scalar < 0) scalar = 0;
    if (scalar > 1) scalar = 1;
    return kVolumeMinDB + scalar * (kVolumeMaxDB - kVolumeMinDB);
}

static Float32 dbToScalar(Float32 db) {
    if (db < kVolumeMinDB) db = kVolumeMinDB;
    if (db > kVolumeMaxDB) db = kVolumeMaxDB;
    return (db - kVolumeMinDB) / (kVolumeMaxDB - kVolumeMinDB);
}

static AudioStreamBasicDescription streamFormat(void) {
    AudioStreamBasicDescription f;
    memset(&f, 0, sizeof(f));
    f.mSampleRate = kSampleRate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked;
    f.mBytesPerPacket = kBytesPerFrame;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = kBytesPerFrame;
    f.mChannelsPerFrame = kChannelCount;
    f.mBitsPerChannel = 32;
    return f;
}

static void notify(AudioObjectID object, const AudioObjectPropertyAddress* addresses, UInt32 count) {
    if (gHost != NULL) gHost->PropertiesChanged(gHost, object, count, addresses);
}

static void storeNumber(CFStringRef key, CFNumberType type, const void* value) {
    if (gHost == NULL) return;
    CFNumberRef number = CFNumberCreate(NULL, type, value);
    if (number == NULL) return;
    gHost->WriteToStorage(gHost, key, number);
    CFRelease(number);
}

static bool loadNumber(CFStringRef key, CFNumberType type, void* value) {
    if (gHost == NULL) return false;
    CFPropertyListRef stored = NULL;
    if (gHost->CopyFromStorage(gHost, key, &stored) != kAudioHardwareNoError || stored == NULL) return false;
    bool ok = CFGetTypeID(stored) == CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)stored, type, value);
    CFRelease(stored);
    return ok;
}

// --- Prototypes de l'interface ---

static HRESULT APB_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG APB_AddRef(void* inDriver);
static ULONG APB_Release(void* inDriver);
static OSStatus APB_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus APB_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus APB_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus APB_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus APB_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus APB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo);
static OSStatus APB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction, void* inChangeInfo);
static Boolean APB_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                               const AudioObjectPropertyAddress* inAddress);
static OSStatus APB_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                       Boolean* outIsSettable);
static OSStatus APB_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus APB_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize,
                                    UInt32* outDataSize, void* outData);
static OSStatus APB_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize,
                                    const void* inData);
static OSStatus APB_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus APB_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus APB_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed);
static OSStatus APB_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                      Boolean* outWillDoInPlace);
static OSStatus APB_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo);
static OSStatus APB_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer);
static OSStatus APB_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo);

static AudioServerPlugInDriverInterface gInterface = {
    NULL,
    APB_QueryInterface,
    APB_AddRef,
    APB_Release,
    APB_Initialize,
    APB_CreateDevice,
    APB_DestroyDevice,
    APB_AddDeviceClient,
    APB_RemoveDeviceClient,
    APB_PerformDeviceConfigurationChange,
    APB_AbortDeviceConfigurationChange,
    APB_HasProperty,
    APB_IsPropertySettable,
    APB_GetPropertyDataSize,
    APB_GetPropertyData,
    APB_SetPropertyData,
    APB_StartIO,
    APB_StopIO,
    APB_GetZeroTimeStamp,
    APB_WillDoIOOperation,
    APB_BeginIOOperation,
    APB_DoIOOperation,
    APB_EndIOOperation,
};
static AudioServerPlugInDriverInterface* gInterfacePtr = &gInterface;
static AudioServerPlugInDriverRef gDriverRef = &gInterfacePtr;

// --- Fabrique CFPlugIn (nommée dans Info.plist, CFPlugInFactories) ---

void* APBOutput_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);
void* APBOutput_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (!CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    return gDriverRef;
}

// --- IUnknown ---

static HRESULT APB_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef || outInterface == NULL) return kAudioHardwareBadObjectError;
    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result = E_NOINTERFACE;
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        atomic_fetch_add(&gRefCount, 1);
        *outInterface = gDriverRef;
        result = S_OK;
    }
    CFRelease(requested);
    return result;
}

static ULONG APB_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    return atomic_fetch_add(&gRefCount, 1) + 1;
}

static ULONG APB_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    UInt32 current = atomic_load(&gRefCount);
    while (current > 0 && !atomic_compare_exchange_weak(&gRefCount, &current, current - 1)) {}
    return current > 0 ? current - 1 : 0;
}

// --- Opérations de base ---

static OSStatus APB_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    gLog = os_log_create("fr.baptiste.airplaypersonalbridge.output", "driver");
    gHost = inHost;

    mach_timebase_info_data_t timebase;
    mach_timebase_info(&timebase);
    Float64 ticksPerSecond = 1.0e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
    atomic_store(&gAnchorHostTime, mach_absolute_time());

    SInt32 latency = 0;
    Float32 volume = 1.0f;
    SInt32 mute = 0;
    pthread_mutex_lock(&gState);
    if (loadNumber(kStorageKeyLatency, kCFNumberSInt32Type, &latency) && latency >= 0
        && (UInt32)latency <= kMaxLatencyFrames) {
        gLatencyFrames = (UInt32)latency;
    }
    if (loadNumber(kStorageKeyVolume, kCFNumberFloat32Type, &volume) && volume >= 0 && volume <= 1) {
        gVolumeScalar = volume;
    }
    if (loadNumber(kStorageKeyMute, kCFNumberSInt32Type, &mute)) gMute = mute != 0;
    UInt32 loadedLatency = gLatencyFrames;
    pthread_mutex_unlock(&gState);

    os_log(gLog, "APBOutput chargé : latence annoncée %u trames (%.3f s)", loadedLatency,
           loadedLatency / kSampleRate);
    return kAudioHardwareNoError;
}

static OSStatus APB_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription,
                                 const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus APB_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus APB_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                    const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus APB_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                       const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus APB_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                     UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus APB_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                                   UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

// --- Propriétés ---
//
// Un objet ne répond qu'aux propriétés que `HasProperty` déclare ; `GetPropertyDataSize` et
// `GetPropertyData` suivent la même liste, objet par objet.

static bool isOutputOrGlobal(AudioObjectPropertyScope scope) {
    return scope == kAudioObjectPropertyScopeGlobal || scope == kAudioObjectPropertyScopeOutput;
}

static Boolean plugInHas(const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
    case kAudioPlugInPropertyTranslateUIDToDevice:
    case kAudioPlugInPropertyResourceBundle:
        return true;
    }
    return false;
}

static Boolean deviceHas(const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioObjectPropertyCustomPropertyInfoList:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioDevicePropertyTransportType:
    case kAudioDevicePropertyRelatedDevices:
    case kAudioDevicePropertyClockDomain:
    case kAudioDevicePropertyDeviceIsAlive:
    case kAudioDevicePropertyDeviceIsRunning:
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
    case kAudioDevicePropertyLatency:
    case kAudioDevicePropertyStreams:
    case kAudioObjectPropertyControlList:
    case kAudioDevicePropertySafetyOffset:
    case kAudioDevicePropertyNominalSampleRate:
    case kAudioDevicePropertyAvailableNominalSampleRates:
    case kAudioDevicePropertyIsHidden:
    case kAudioDevicePropertyZeroTimeStampPeriod:
    case kAudioDevicePropertyClockIsStable:
    case kAPB_PropertyLatencyFrames:
        return true;
    case kAudioDevicePropertyPreferredChannelsForStereo:
    case kAudioDevicePropertyPreferredChannelLayout:
        return isOutputOrGlobal(a->mScope);
    }
    return false;
}

static Boolean streamHas(const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioStreamPropertyIsActive:
    case kAudioStreamPropertyDirection:
    case kAudioStreamPropertyTerminalType:
    case kAudioStreamPropertyStartingChannel:
    case kAudioStreamPropertyLatency:
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats:
        return true;
    }
    return false;
}

static Boolean volumeHas(const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioControlPropertyScope:
    case kAudioControlPropertyElement:
    case kAudioLevelControlPropertyScalarValue:
    case kAudioLevelControlPropertyDecibelValue:
    case kAudioLevelControlPropertyDecibelRange:
    case kAudioLevelControlPropertyConvertScalarToDecibels:
    case kAudioLevelControlPropertyConvertDecibelsToScalar:
        return true;
    }
    return false;
}

static Boolean muteHas(const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
    case kAudioObjectPropertyOwnedObjects:
    case kAudioControlPropertyScope:
    case kAudioControlPropertyElement:
    case kAudioBooleanControlPropertyValue:
        return true;
    }
    return false;
}

static Boolean APB_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID,
                               const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    switch (inObjectID) {
    case kObjectID_PlugIn: return plugInHas(inAddress);
    case kObjectID_Device: return deviceHas(inAddress);
    case kObjectID_Stream: return streamHas(inAddress);
    case kObjectID_Volume: return volumeHas(inAddress);
    case kObjectID_Mute: return muteHas(inAddress);
    }
    return false;
}

static OSStatus APB_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                       pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                       Boolean* outIsSettable) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    if (!APB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    *outIsSettable = false;
    switch (inObjectID) {
    case kObjectID_Device:
        *outIsSettable = inAddress->mSelector == kAPB_PropertyLatencyFrames;
        break;
    case kObjectID_Volume:
        *outIsSettable = inAddress->mSelector == kAudioLevelControlPropertyScalarValue
            || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue;
        break;
    case kObjectID_Mute:
        *outIsSettable = inAddress->mSelector == kAudioBooleanControlPropertyValue;
        break;
    }
    return kAudioHardwareNoError;
}

// Taille des données d'une propriété, ou 0 si elle dépend de la portée et qu'elle y est vide.
static UInt32 propertySize(AudioObjectID object, const AudioObjectPropertyAddress* a) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass:
    case kAudioObjectPropertyClass:
    case kAudioObjectPropertyOwner:
        return sizeof(AudioClassID);
    case kAudioObjectPropertyName:
    case kAudioObjectPropertyManufacturer:
    case kAudioDevicePropertyDeviceUID:
    case kAudioDevicePropertyModelUID:
    case kAudioPlugInPropertyResourceBundle:
        return sizeof(CFStringRef);
    }
    switch (object) {
    case kObjectID_PlugIn:
        switch (a->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
        case kAudioPlugInPropertyDeviceList:
        case kAudioPlugInPropertyTranslateUIDToDevice:
            return sizeof(AudioObjectID);
        }
        break;
    case kObjectID_Device:
        switch (a->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
            if (a->mScope == kAudioObjectPropertyScopeGlobal) return 3 * sizeof(AudioObjectID);
            if (a->mScope == kAudioObjectPropertyScopeOutput) return 3 * sizeof(AudioObjectID);
            return 0;
        case kAudioDevicePropertyStreams:
            return isOutputOrGlobal(a->mScope) ? sizeof(AudioObjectID) : 0;
        case kAudioObjectPropertyControlList:
            return 2 * sizeof(AudioObjectID);
        case kAudioDevicePropertyRelatedDevices:
            return sizeof(AudioObjectID);
        case kAudioObjectPropertyCustomPropertyInfoList:
            return sizeof(AudioServerPlugInCustomPropertyInfo);
        case kAPB_PropertyLatencyFrames:
            return sizeof(CFPropertyListRef);
        case kAudioDevicePropertyNominalSampleRate:
            return sizeof(Float64);
        case kAudioDevicePropertyAvailableNominalSampleRates:
            return sizeof(AudioValueRange);
        case kAudioDevicePropertyPreferredChannelsForStereo:
            return 2 * sizeof(UInt32);
        case kAudioDevicePropertyPreferredChannelLayout:
            return (UInt32)(offsetof(AudioChannelLayout, mChannelDescriptions) + kChannelCount * sizeof(AudioChannelDescription));
        default:
            return sizeof(UInt32);
        }
    case kObjectID_Stream:
        switch (a->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
            return 0;
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return sizeof(AudioStreamBasicDescription);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats:
            return sizeof(AudioStreamRangedDescription);
        default:
            return sizeof(UInt32);
        }
    case kObjectID_Volume:
        switch (a->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
            return 0;
        case kAudioControlPropertyScope:
            return sizeof(AudioObjectPropertyScope);
        case kAudioControlPropertyElement:
            return sizeof(AudioObjectPropertyElement);
        case kAudioLevelControlPropertyDecibelRange:
            return sizeof(AudioValueRange);
        default:
            return sizeof(Float32);
        }
    case kObjectID_Mute:
        switch (a->mSelector) {
        case kAudioObjectPropertyOwnedObjects:
            return 0;
        case kAudioControlPropertyScope:
            return sizeof(AudioObjectPropertyScope);
        case kAudioControlPropertyElement:
            return sizeof(AudioObjectPropertyElement);
        default:
            return sizeof(UInt32);
        }
    }
    return 0;
}

static OSStatus APB_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                        pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                        UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    if (!APB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    *outDataSize = propertySize(inObjectID, inAddress);
    return kAudioHardwareNoError;
}

static OSStatus getPlugIn(const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, void* out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: *(AudioClassID*)out = kAudioObjectClassID; break;
    case kAudioObjectPropertyClass: *(AudioClassID*)out = kAudioPlugInClassID; break;
    case kAudioObjectPropertyOwner: *(AudioObjectID*)out = kAudioObjectUnknown; break;
    case kAudioObjectPropertyManufacturer: *(CFStringRef*)out = CFSTR(kAPB_Manufacturer); break;
    case kAudioObjectPropertyOwnedObjects:
    case kAudioPlugInPropertyDeviceList:
        *(AudioObjectID*)out = kObjectID_Device;
        break;
    case kAudioPlugInPropertyTranslateUIDToDevice: {
        if (qualSize != sizeof(CFStringRef) || qual == NULL) return kAudioHardwareBadPropertySizeError;
        CFStringRef uid = *(const CFStringRef*)qual;
        *(AudioObjectID*)out = (uid != NULL && CFStringCompare(uid, CFSTR(kAPB_DeviceUID), 0) == kCFCompareEqualTo)
            ? kObjectID_Device : kAudioObjectUnknown;
        break;
    }
    case kAudioPlugInPropertyResourceBundle: *(CFStringRef*)out = CFSTR(""); break;
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareNoError;
}

static OSStatus getDevice(const AudioObjectPropertyAddress* a, void* out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: *(AudioClassID*)out = kAudioObjectClassID; break;
    case kAudioObjectPropertyClass: *(AudioClassID*)out = kAudioDeviceClassID; break;
    case kAudioObjectPropertyOwner: *(AudioObjectID*)out = kObjectID_PlugIn; break;
    case kAudioObjectPropertyName: *(CFStringRef*)out = CFSTR(kAPB_DeviceName); break;
    case kAudioObjectPropertyManufacturer: *(CFStringRef*)out = CFSTR(kAPB_Manufacturer); break;
    case kAudioDevicePropertyDeviceUID: *(CFStringRef*)out = CFSTR(kAPB_DeviceUID); break;
    case kAudioDevicePropertyModelUID: *(CFStringRef*)out = CFSTR(kAPB_ModelUID); break;
    case kAudioObjectPropertyOwnedObjects: {
        AudioObjectID* ids = out;
        if (isOutputOrGlobal(a->mScope)) {
            ids[0] = kObjectID_Stream;
            ids[1] = kObjectID_Volume;
            ids[2] = kObjectID_Mute;
        }
        break;
    }
    case kAudioDevicePropertyStreams:
        if (isOutputOrGlobal(a->mScope)) *(AudioObjectID*)out = kObjectID_Stream;
        break;
    case kAudioObjectPropertyControlList: {
        AudioObjectID* ids = out;
        ids[0] = kObjectID_Volume;
        ids[1] = kObjectID_Mute;
        break;
    }
    case kAudioObjectPropertyCustomPropertyInfoList: {
        AudioServerPlugInCustomPropertyInfo* info = out;
        info->mSelector = kAPB_PropertyLatencyFrames;
        info->mPropertyDataType = kAudioServerPlugInCustomPropertyDataTypeCFPropertyList;
        info->mQualifierDataType = kAudioServerPlugInCustomPropertyDataTypeNone;
        break;
    }
    case kAPB_PropertyLatencyFrames: {
        pthread_mutex_lock(&gState);
        SInt32 frames = (SInt32)gLatencyFrames;
        pthread_mutex_unlock(&gState);
        // L'hôte libère la valeur rendue.
        *(CFPropertyListRef*)out = CFNumberCreate(NULL, kCFNumberSInt32Type, &frames);
        break;
    }
    case kAudioDevicePropertyTransportType: *(UInt32*)out = kAudioDeviceTransportTypeVirtual; break;
    case kAudioDevicePropertyRelatedDevices: *(AudioObjectID*)out = kObjectID_Device; break;
    case kAudioDevicePropertyClockDomain: *(UInt32*)out = 0; break;
    case kAudioDevicePropertyDeviceIsAlive: *(UInt32*)out = 1; break;
    case kAudioDevicePropertyDeviceIsRunning:
        pthread_mutex_lock(&gState);
        *(UInt32*)out = gIOClientCount > 0 ? 1 : 0;
        pthread_mutex_unlock(&gState);
        break;
    case kAudioDevicePropertyDeviceCanBeDefaultDevice:
    case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
        *(UInt32*)out = a->mScope == kAudioObjectPropertyScopeInput ? 0 : 1;
        break;
    case kAudioDevicePropertyLatency:
        // Le cœur du pilote : c'est cette valeur que Chromium ajoute au retard de l'image.
        pthread_mutex_lock(&gState);
        *(UInt32*)out = a->mScope == kAudioObjectPropertyScopeInput ? 0 : gLatencyFrames;
        pthread_mutex_unlock(&gState);
        break;
    case kAudioDevicePropertySafetyOffset: *(UInt32*)out = 0; break;
    case kAudioDevicePropertyNominalSampleRate: *(Float64*)out = kSampleRate; break;
    case kAudioDevicePropertyAvailableNominalSampleRates: {
        AudioValueRange* range = out;
        range->mMinimum = kSampleRate;
        range->mMaximum = kSampleRate;
        break;
    }
    case kAudioDevicePropertyIsHidden: *(UInt32*)out = 0; break;
    case kAudioDevicePropertyZeroTimeStampPeriod: *(UInt32*)out = kZeroTimeStampPeriod; break;
    case kAudioDevicePropertyClockIsStable: *(UInt32*)out = 1; break;
    case kAudioDevicePropertyPreferredChannelsForStereo: {
        UInt32* channels = out;
        channels[0] = 1;
        channels[1] = 2;
        break;
    }
    case kAudioDevicePropertyPreferredChannelLayout: {
        AudioChannelLayout* layout = out;
        memset(layout, 0, propertySize(kObjectID_Device, a));
        layout->mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
        layout->mNumberChannelDescriptions = kChannelCount;
        layout->mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
        layout->mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
        break;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareNoError;
}

static OSStatus getStream(const AudioObjectPropertyAddress* a, void* out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: *(AudioClassID*)out = kAudioObjectClassID; break;
    case kAudioObjectPropertyClass: *(AudioClassID*)out = kAudioStreamClassID; break;
    case kAudioObjectPropertyOwner: *(AudioObjectID*)out = kObjectID_Device; break;
    case kAudioObjectPropertyOwnedObjects: break;
    case kAudioStreamPropertyIsActive: *(UInt32*)out = 1; break;
    case kAudioStreamPropertyDirection: *(UInt32*)out = 0; break; // 0 = sortie
    case kAudioStreamPropertyTerminalType: *(UInt32*)out = kAudioStreamTerminalTypeSpeaker; break;
    case kAudioStreamPropertyStartingChannel: *(UInt32*)out = 1; break;
    case kAudioStreamPropertyLatency: *(UInt32*)out = 0; break;
    case kAudioStreamPropertyVirtualFormat:
    case kAudioStreamPropertyPhysicalFormat:
        *(AudioStreamBasicDescription*)out = streamFormat();
        break;
    case kAudioStreamPropertyAvailableVirtualFormats:
    case kAudioStreamPropertyAvailablePhysicalFormats: {
        AudioStreamRangedDescription* ranged = out;
        ranged->mFormat = streamFormat();
        ranged->mSampleRateRange.mMinimum = kSampleRate;
        ranged->mSampleRateRange.mMaximum = kSampleRate;
        break;
    }
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareNoError;
}

static OSStatus getVolume(const AudioObjectPropertyAddress* a, UInt32 qualSize, const void* qual, void* out) {
    (void)qualSize; (void)qual;
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: *(AudioClassID*)out = kAudioLevelControlClassID; break;
    case kAudioObjectPropertyClass: *(AudioClassID*)out = kAudioVolumeControlClassID; break;
    case kAudioObjectPropertyOwner: *(AudioObjectID*)out = kObjectID_Device; break;
    case kAudioObjectPropertyOwnedObjects: break;
    case kAudioControlPropertyScope: *(AudioObjectPropertyScope*)out = kAudioObjectPropertyScopeOutput; break;
    case kAudioControlPropertyElement: *(AudioObjectPropertyElement*)out = kAudioObjectPropertyElementMain; break;
    case kAudioLevelControlPropertyScalarValue:
        pthread_mutex_lock(&gState);
        *(Float32*)out = gVolumeScalar;
        pthread_mutex_unlock(&gState);
        break;
    case kAudioLevelControlPropertyDecibelValue:
        pthread_mutex_lock(&gState);
        *(Float32*)out = scalarToDB(gVolumeScalar);
        pthread_mutex_unlock(&gState);
        break;
    case kAudioLevelControlPropertyDecibelRange: {
        AudioValueRange* range = out;
        range->mMinimum = kVolumeMinDB;
        range->mMaximum = kVolumeMaxDB;
        break;
    }
    // Pour ces deux conversions, la valeur à convertir arrive dans le tampon de sortie.
    case kAudioLevelControlPropertyConvertScalarToDecibels: *(Float32*)out = scalarToDB(*(Float32*)out); break;
    case kAudioLevelControlPropertyConvertDecibelsToScalar: *(Float32*)out = dbToScalar(*(Float32*)out); break;
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareNoError;
}

static OSStatus getMute(const AudioObjectPropertyAddress* a, void* out) {
    switch (a->mSelector) {
    case kAudioObjectPropertyBaseClass: *(AudioClassID*)out = kAudioBooleanControlClassID; break;
    case kAudioObjectPropertyClass: *(AudioClassID*)out = kAudioMuteControlClassID; break;
    case kAudioObjectPropertyOwner: *(AudioObjectID*)out = kObjectID_Device; break;
    case kAudioObjectPropertyOwnedObjects: break;
    case kAudioControlPropertyScope: *(AudioObjectPropertyScope*)out = kAudioObjectPropertyScopeOutput; break;
    case kAudioControlPropertyElement: *(AudioObjectPropertyElement*)out = kAudioObjectPropertyElementMain; break;
    case kAudioBooleanControlPropertyValue:
        pthread_mutex_lock(&gState);
        *(UInt32*)out = gMute ? 1 : 0;
        pthread_mutex_unlock(&gState);
        break;
    default: return kAudioHardwareUnknownPropertyError;
    }
    return kAudioHardwareNoError;
}

static OSStatus APB_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize,
                                    UInt32* outDataSize, void* outData) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    if (!APB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    UInt32 size = propertySize(inObjectID, inAddress);
    if (inDataSize < size) return kAudioHardwareBadPropertySizeError;
    OSStatus status;
    switch (inObjectID) {
    case kObjectID_PlugIn: status = getPlugIn(inAddress, inQualifierDataSize, inQualifierData, outData); break;
    case kObjectID_Device: status = getDevice(inAddress, outData); break;
    case kObjectID_Stream: status = getStream(inAddress, outData); break;
    case kObjectID_Volume: status = getVolume(inAddress, inQualifierDataSize, inQualifierData, outData); break;
    case kObjectID_Mute: status = getMute(inAddress, outData); break;
    default: return kAudioHardwareBadObjectError;
    }
    if (status == kAudioHardwareNoError) *outDataSize = size;
    return status;
}

static OSStatus setLatency(const void* inData, UInt32 inDataSize) {
    if (inDataSize != sizeof(CFPropertyListRef)) return kAudioHardwareBadPropertySizeError;
    CFPropertyListRef value = *(const CFPropertyListRef*)inData;
    SInt32 frames = -1;
    if (value == NULL || CFGetTypeID(value) != CFNumberGetTypeID()
        || !CFNumberGetValue((CFNumberRef)value, kCFNumberSInt32Type, &frames)) {
        return kAudioHardwareIllegalOperationError;
    }
    if (frames < 0 || (UInt32)frames > kMaxLatencyFrames) return kAudioHardwareIllegalOperationError;

    pthread_mutex_lock(&gState);
    bool changed = gLatencyFrames != (UInt32)frames;
    gLatencyFrames = (UInt32)frames;
    pthread_mutex_unlock(&gState);
    if (!changed) return kAudioHardwareNoError;

    storeNumber(kStorageKeyLatency, kCFNumberSInt32Type, &frames);
    os_log(gLog, "Latence annoncée : %d trames (%.3f s)", frames, frames / kSampleRate);
    // La latence ne change ni l'IO ni la structure du périphérique : une simple notification suffit,
    // sans reconfiguration qui interromprait les clients (la capture de l'app en est un).
    AudioObjectPropertyAddress changes[] = {
        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, kAudioObjectPropertyElementMain },
        { kAudioDevicePropertyLatency, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAPB_PropertyLatencyFrames, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    notify(kObjectID_Device, changes, 3);
    return kAudioHardwareNoError;
}

static OSStatus setVolume(const AudioObjectPropertyAddress* a, const void* inData, UInt32 inDataSize) {
    if (inDataSize != sizeof(Float32)) return kAudioHardwareBadPropertySizeError;
    Float32 value = *(const Float32*)inData;
    if (isnan(value)) return kAudioHardwareIllegalOperationError;
    Float32 scalar = a->mSelector == kAudioLevelControlPropertyDecibelValue ? dbToScalar(value) : value;
    if (scalar < 0) scalar = 0;
    if (scalar > 1) scalar = 1;

    pthread_mutex_lock(&gState);
    bool changed = gVolumeScalar != scalar;
    gVolumeScalar = scalar;
    pthread_mutex_unlock(&gState);
    if (!changed) return kAudioHardwareNoError;

    storeNumber(kStorageKeyVolume, kCFNumberFloat32Type, &scalar);
    AudioObjectPropertyAddress changes[] = {
        { kAudioLevelControlPropertyScalarValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
        { kAudioLevelControlPropertyDecibelValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    notify(kObjectID_Volume, changes, 2);
    return kAudioHardwareNoError;
}

static OSStatus setMute(const void* inData, UInt32 inDataSize) {
    if (inDataSize != sizeof(UInt32)) return kAudioHardwareBadPropertySizeError;
    bool mute = *(const UInt32*)inData != 0;

    pthread_mutex_lock(&gState);
    bool changed = gMute != mute;
    gMute = mute;
    pthread_mutex_unlock(&gState);
    if (!changed) return kAudioHardwareNoError;

    SInt32 stored = mute ? 1 : 0;
    storeNumber(kStorageKeyMute, kCFNumberSInt32Type, &stored);
    AudioObjectPropertyAddress changes[] = {
        { kAudioBooleanControlPropertyValue, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain },
    };
    notify(kObjectID_Mute, changes, 1);
    return kAudioHardwareNoError;
}

static OSStatus APB_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID,
                                    pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress,
                                    UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize,
                                    const void* inData) {
    (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || inData == NULL) return kAudioHardwareIllegalOperationError;
    if (!APB_HasProperty(inDriver, inObjectID, inClientProcessID, inAddress)) return kAudioHardwareUnknownPropertyError;
    if (inObjectID == kObjectID_Device && inAddress->mSelector == kAPB_PropertyLatencyFrames) {
        return setLatency(inData, inDataSize);
    }
    if (inObjectID == kObjectID_Volume && (inAddress->mSelector == kAudioLevelControlPropertyScalarValue
                                           || inAddress->mSelector == kAudioLevelControlPropertyDecibelValue)) {
        return setVolume(inAddress, inData, inDataSize);
    }
    if (inObjectID == kObjectID_Mute && inAddress->mSelector == kAudioBooleanControlPropertyValue) {
        return setMute(inData, inDataSize);
    }
    return kAudioHardwareUnsupportedOperationError;
}

// --- IO ---

static OSStatus APB_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gState);
    if (gIOClientCount == UINT32_MAX) {
        pthread_mutex_unlock(&gState);
        return kAudioHardwareIllegalOperationError;
    }
    // Premier client : l'horloge repart de maintenant. Aucune IO ne tourne encore, le chemin d'IO ne
    // lit donc pas l'ancre pendant qu'on l'écrit.
    if (gIOClientCount == 0) atomic_store(&gAnchorHostTime, mach_absolute_time());
    gIOClientCount += 1;
    UInt32 clients = gIOClientCount;
    pthread_mutex_unlock(&gState);
    os_log_debug(gLog, "StartIO, %u client(s)", clients);
    return kAudioHardwareNoError;
}

static OSStatus APB_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    pthread_mutex_lock(&gState);
    if (gIOClientCount > 0) gIOClientCount -= 1;
    UInt32 clients = gIOClientCount;
    pthread_mutex_unlock(&gState);
    os_log_debug(gLog, "StopIO, %u client(s)", clients);
    return kAudioHardwareNoError;
}

// Chemin d'IO : ni verrou, ni allocation, ni journal. L'horloge est une fonction pure de l'ancre et de
// l'heure hôte : la période courante est le nombre entier de périodes écoulées depuis l'ancre.
static OSStatus APB_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    UInt64 anchor = atomic_load_explicit(&gAnchorHostTime, memory_order_acquire);
    UInt64 now = mach_absolute_time();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kZeroTimeStampPeriod;
    UInt64 periods = now > anchor ? (UInt64)((Float64)(now - anchor) / ticksPerPeriod) : 0;
    *outSampleTime = (Float64)(periods * kZeroTimeStampPeriod);
    *outHostTime = anchor + (UInt64)((Float64)periods * ticksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus APB_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                      UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo,
                                      Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    // Seul le mixage de sortie est accepté, puis jeté : le son réel est capté en amont par le tap.
    *outWillDo = inOperationID == kAudioServerPlugInIOOperationWriteMix;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus APB_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                     UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                     const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus APB_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                  AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID,
                                  UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo,
                                  void* ioMainBuffer, void* ioSecondaryBuffer) {
    (void)inStreamObjectID; (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize;
    (void)inIOCycleInfo; (void)ioMainBuffer; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}

static OSStatus APB_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID,
                                   UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize,
                                   const AudioServerPlugInIOCycleInfo* inIOCycleInfo) {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef || inDeviceObjectID != kObjectID_Device) return kAudioHardwareBadObjectError;
    return kAudioHardwareNoError;
}
