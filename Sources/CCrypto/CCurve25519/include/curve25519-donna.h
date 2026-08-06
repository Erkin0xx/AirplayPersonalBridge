/* En-tête écrit pour ce projet : curve25519-donna (agl/curve25519-donna, commit f7837ad)
 * ne fournit aucun .h, seulement les .c. SwiftPM exige un en-tête public dans include/
 * pour exposer le symbole au module map.
 *
 * La déclaration est recopiée telle quelle depuis curve25519-donna-c64.c (ligne 430),
 * avec les types explicités : u8 y est un typedef de uint8_t.
 */

#ifndef CURVE25519_DONNA_H
#define CURVE25519_DONNA_H

#include <stdint.h>

/* Diffie-Hellman X25519.
 * mypublic  : 32 octets de sortie
 * secret    : 32 octets de clé privée (déjà « clampée » par l'appelant ou par donna)
 * basepoint : 32 octets — la base {9} pour dériver une clé publique, ou la clé
 *             publique du pair pour calculer le secret partagé.
 * Retourne 0 en succès.
 */
int curve25519_donna(uint8_t *mypublic, const uint8_t *secret, const uint8_t *basepoint);

#endif /* CURVE25519_DONNA_H */
