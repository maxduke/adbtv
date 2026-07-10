#ifndef C_ADB_PAIRING_CRYPTO_H
#define C_ADB_PAIRING_CRYPTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ADBPairingCryptoContext ADBPairingCryptoContext;

enum {
    ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT = 32,
    ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT = 64,
    ADB_PAIRING_CRYPTO_MAX_CERTIFICATE_BYTE_COUNT = 4096,
};

ADBPairingCryptoContext *adb_pairing_crypto_client_create(
    const uint8_t *password,
    size_t password_length
);

ADBPairingCryptoContext *adb_pairing_crypto_server_create(
    const uint8_t *password,
    size_t password_length
);

bool adb_pairing_crypto_copy_message(
    const ADBPairingCryptoContext *context,
    uint8_t output[ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT]
);

bool adb_pairing_crypto_process_message(
    ADBPairingCryptoContext *context,
    const uint8_t *peer_message,
    size_t peer_message_length,
    uint8_t output_key_material[ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT]
);

bool adb_pairing_crypto_generate_certificate(
    const uint8_t *rsa_private_key_der,
    size_t rsa_private_key_der_length,
    uint8_t *output_certificate_der,
    size_t output_capacity,
    size_t *output_certificate_der_length
);

void adb_pairing_crypto_destroy(ADBPairingCryptoContext *context);

#ifdef __cplusplus
}
#endif

#endif
