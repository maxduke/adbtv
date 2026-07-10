#ifndef C_ADB_PAIRING_CRYPTO_H
#define C_ADB_PAIRING_CRYPTO_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ADBPairingCryptoContext ADBPairingCryptoContext;
typedef struct ADBTLSContext ADBTLSContext;

typedef enum {
    ADB_TLS_ROLE_CLIENT = 0,
    ADB_TLS_ROLE_SERVER = 1,
} ADBTLSRole;

typedef enum {
    ADB_TLS_RESULT_ERROR = -1,
    ADB_TLS_RESULT_COMPLETE = 0,
    ADB_TLS_RESULT_WANT_READ = 1,
    ADB_TLS_RESULT_WANT_WRITE = 2,
    ADB_TLS_RESULT_CLOSED = 3,
} ADBTLSResult;

enum {
    ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT = 32,
    ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT = 64,
    ADB_PAIRING_CRYPTO_MAX_CERTIFICATE_BYTE_COUNT = 4096,
    ADB_PAIRING_CRYPTO_MAX_PKCS12_BYTE_COUNT = 8192,
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

bool adb_pairing_crypto_generate_pkcs12(
    const uint8_t *rsa_private_key_der,
    size_t rsa_private_key_der_length,
    const char *password,
    uint8_t *output_pkcs12_der,
    size_t output_capacity,
    size_t *output_pkcs12_der_length
);

ADBTLSContext *adb_tls_create(
    ADBTLSRole role,
    const uint8_t *certificate_pem,
    size_t certificate_pem_length,
    const uint8_t *private_key_pem,
    size_t private_key_pem_length
);

ADBTLSResult adb_tls_handshake(ADBTLSContext *context);

bool adb_tls_provide_encrypted_input(
    ADBTLSContext *context,
    const uint8_t *bytes,
    size_t byte_count
);

size_t adb_tls_pending_encrypted_output(const ADBTLSContext *context);

bool adb_tls_copy_encrypted_output(
    ADBTLSContext *context,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_byte_count
);

ADBTLSResult adb_tls_write_plaintext(
    ADBTLSContext *context,
    const uint8_t *bytes,
    size_t byte_count,
    size_t *consumed_byte_count
);

ADBTLSResult adb_tls_read_plaintext(
    ADBTLSContext *context,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_byte_count
);

bool adb_tls_has_peer_certificate(const ADBTLSContext *context);

void adb_tls_destroy(ADBTLSContext *context);

void adb_pairing_crypto_destroy(ADBPairingCryptoContext *context);

#ifdef __cplusplus
}
#endif

#endif
