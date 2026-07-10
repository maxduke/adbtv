#include "CADBPairingCrypto.h"

#include <openssl/curve25519.h>

#include <stdlib.h>
#include <string.h>

struct ADBPairingCryptoContext {
    SPAKE2_CTX *spake2;
    uint8_t message[ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT];
    size_t message_length;
    bool did_process_message;
};

typedef enum {
    ADB_PAIRING_CRYPTO_ROLE_CLIENT = 0,
    ADB_PAIRING_CRYPTO_ROLE_SERVER = 1,
} ADBPairingCryptoRole;

static const uint8_t client_name[] = "adb pair client";
static const uint8_t server_name[] = "adb pair server";

static ADBPairingCryptoContext *create_context(
    ADBPairingCryptoRole role,
    const uint8_t *password,
    size_t password_length
) {
    if (password == NULL || password_length == 0) {
        return NULL;
    }

    enum spake2_role_t spake2_role;
    const uint8_t *local_name;
    size_t local_name_length;
    const uint8_t *peer_name;
    size_t peer_name_length;

    switch (role) {
        case ADB_PAIRING_CRYPTO_ROLE_CLIENT:
            spake2_role = spake2_role_alice;
            local_name = client_name;
            local_name_length = sizeof(client_name);
            peer_name = server_name;
            peer_name_length = sizeof(server_name);
            break;
        case ADB_PAIRING_CRYPTO_ROLE_SERVER:
            spake2_role = spake2_role_bob;
            local_name = server_name;
            local_name_length = sizeof(server_name);
            peer_name = client_name;
            peer_name_length = sizeof(client_name);
            break;
        default:
            return NULL;
    }

    ADBPairingCryptoContext *context = static_cast<ADBPairingCryptoContext *>(
        calloc(1, sizeof(ADBPairingCryptoContext))
    );
    if (context == NULL) {
        return NULL;
    }

    context->spake2 = SPAKE2_CTX_new(
        spake2_role,
        local_name,
        local_name_length,
        peer_name,
        peer_name_length
    );
    if (context->spake2 == NULL) {
        free(context);
        return NULL;
    }

    if (SPAKE2_generate_msg(
            context->spake2,
            context->message,
            &context->message_length,
            sizeof(context->message),
            password,
            password_length
        ) != 1 || context->message_length != sizeof(context->message)) {
        adb_pairing_crypto_destroy(context);
        return NULL;
    }

    return context;
}

ADBPairingCryptoContext *adb_pairing_crypto_client_create(
    const uint8_t *password,
    size_t password_length
) {
    return create_context(ADB_PAIRING_CRYPTO_ROLE_CLIENT, password, password_length);
}

ADBPairingCryptoContext *adb_pairing_crypto_server_create(
    const uint8_t *password,
    size_t password_length
) {
    return create_context(ADB_PAIRING_CRYPTO_ROLE_SERVER, password, password_length);
}

bool adb_pairing_crypto_copy_message(
    const ADBPairingCryptoContext *context,
    uint8_t output[ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT]
) {
    if (context == NULL || output == NULL || context->message_length != sizeof(context->message)) {
        return false;
    }

    memcpy(output, context->message, sizeof(context->message));
    return true;
}

bool adb_pairing_crypto_process_message(
    ADBPairingCryptoContext *context,
    const uint8_t *peer_message,
    size_t peer_message_length,
    uint8_t output_key_material[ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT]
) {
    if (context == NULL || context->spake2 == NULL || context->did_process_message ||
        peer_message == NULL || peer_message_length != ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT ||
        output_key_material == NULL) {
        return false;
    }

    context->did_process_message = true;
    size_t key_material_length = 0;
    int result = SPAKE2_process_msg(
        context->spake2,
        output_key_material,
        &key_material_length,
        ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT,
        peer_message,
        peer_message_length
    );
    return result == 1 && key_material_length == ADB_PAIRING_CRYPTO_KEY_MATERIAL_BYTE_COUNT;
}

void adb_pairing_crypto_destroy(ADBPairingCryptoContext *context) {
    if (context == NULL) {
        return;
    }

    if (context->spake2 != NULL) {
        SPAKE2_CTX_free(context->spake2);
    }
    memset(context, 0, sizeof(ADBPairingCryptoContext));
    free(context);
}
