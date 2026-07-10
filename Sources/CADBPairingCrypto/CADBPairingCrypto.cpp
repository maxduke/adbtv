#include "CADBPairingCrypto.h"

#include <openssl/curve25519.h>
#include <openssl/evp.h>
#include <openssl/obj.h>
#include <openssl/pkcs8.h>
#include <openssl/rsa.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <stdlib.h>
#include <string.h>

#include <vector>

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
static const char basic_constraints[] = "critical,CA:TRUE";
static const char key_usage[] = "critical,keyCertSign,cRLSign,digitalSignature";
static const char subject_key_identifier[] = "hash";
static const long certificate_lifetime_seconds = 10L * 365L * 24L * 60L * 60L;

static bool add_certificate_extension(X509 *certificate, int identifier, const char *value) {
    std::vector<char> mutable_value(value, value + strlen(value) + 1);
    X509V3_CTX context;
    X509V3_set_ctx_nodb(&context);
    X509V3_set_ctx(&context, certificate, certificate, nullptr, nullptr, 0);

    X509_EXTENSION *extension = X509V3_EXT_nconf_nid(
        nullptr,
        &context,
        identifier,
        mutable_value.data()
    );
    if (extension == nullptr) {
        return false;
    }

    int result = X509_add_ext(certificate, extension, -1);
    X509_EXTENSION_free(extension);
    return result == 1;
}

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

bool adb_pairing_crypto_generate_certificate(
    const uint8_t *rsa_private_key_der,
    size_t rsa_private_key_der_length,
    uint8_t *output_certificate_der,
    size_t output_capacity,
    size_t *output_certificate_der_length
) {
    if (rsa_private_key_der == nullptr || rsa_private_key_der_length == 0 ||
        output_certificate_der == nullptr || output_certificate_der_length == nullptr) {
        return false;
    }
    *output_certificate_der_length = 0;

    RSA *rsa = RSA_private_key_from_bytes(rsa_private_key_der, rsa_private_key_der_length);
    if (rsa == nullptr) {
        return false;
    }

    EVP_PKEY *key = EVP_PKEY_new();
    if (key == nullptr || EVP_PKEY_set1_RSA(key, rsa) != 1) {
        RSA_free(rsa);
        EVP_PKEY_free(key);
        return false;
    }
    RSA_free(rsa);

    X509 *certificate = X509_new();
    if (certificate == nullptr) {
        EVP_PKEY_free(key);
        return false;
    }

    bool configured = X509_set_version(certificate, 2) == 1
        && ASN1_INTEGER_set(X509_get_serialNumber(certificate), 1) == 1
        && X509_gmtime_adj(X509_get_notBefore(certificate), 0) != nullptr
        && X509_gmtime_adj(X509_get_notAfter(certificate), certificate_lifetime_seconds) != nullptr
        && X509_set_pubkey(certificate, key) == 1;

    X509_NAME *name = configured ? X509_get_subject_name(certificate) : nullptr;
    configured = configured && name != nullptr
        && X509_NAME_add_entry_by_txt(
            name,
            "C",
            MBSTRING_ASC,
            reinterpret_cast<const uint8_t *>("US"),
            -1,
            -1,
            0
        ) == 1
        && X509_NAME_add_entry_by_txt(
            name,
            "O",
            MBSTRING_ASC,
            reinterpret_cast<const uint8_t *>("Android"),
            -1,
            -1,
            0
        ) == 1
        && X509_NAME_add_entry_by_txt(
            name,
            "CN",
            MBSTRING_ASC,
            reinterpret_cast<const uint8_t *>("Adb"),
            -1,
            -1,
            0
        ) == 1
        && X509_set_issuer_name(certificate, name) == 1
        && add_certificate_extension(certificate, NID_basic_constraints, basic_constraints)
        && add_certificate_extension(certificate, NID_key_usage, key_usage)
        && add_certificate_extension(certificate, NID_subject_key_identifier, subject_key_identifier)
        && X509_sign(certificate, key, EVP_sha256()) > 0;

    int encoded_length = configured ? i2d_X509(certificate, nullptr) : -1;
    bool can_encode = encoded_length > 0
        && static_cast<size_t>(encoded_length) <= output_capacity;
    if (can_encode) {
        uint8_t *cursor = output_certificate_der;
        can_encode = i2d_X509(certificate, &cursor) == encoded_length;
    }

    X509_free(certificate);
    EVP_PKEY_free(key);

    if (!can_encode) {
        return false;
    }

    *output_certificate_der_length = static_cast<size_t>(encoded_length);
    return true;
}

bool adb_pairing_crypto_generate_pkcs12(
    const uint8_t *rsa_private_key_der,
    size_t rsa_private_key_der_length,
    const char *password,
    uint8_t *output_pkcs12_der,
    size_t output_capacity,
    size_t *output_pkcs12_der_length
) {
    if (rsa_private_key_der == nullptr || rsa_private_key_der_length == 0 || password == nullptr ||
        output_pkcs12_der == nullptr || output_pkcs12_der_length == nullptr) {
        return false;
    }
    *output_pkcs12_der_length = 0;

    uint8_t certificate_der[ADB_PAIRING_CRYPTO_MAX_CERTIFICATE_BYTE_COUNT];
    size_t certificate_der_length = 0;
    if (!adb_pairing_crypto_generate_certificate(
            rsa_private_key_der,
            rsa_private_key_der_length,
            certificate_der,
            sizeof(certificate_der),
            &certificate_der_length
        )) {
        return false;
    }

    const uint8_t *certificate_cursor = certificate_der;
    X509 *certificate = d2i_X509(
        nullptr,
        &certificate_cursor,
        static_cast<long>(certificate_der_length)
    );
    RSA *rsa = RSA_private_key_from_bytes(rsa_private_key_der, rsa_private_key_der_length);
    EVP_PKEY *key = EVP_PKEY_new();
    if (certificate == nullptr || rsa == nullptr || key == nullptr || EVP_PKEY_set1_RSA(key, rsa) != 1) {
        X509_free(certificate);
        RSA_free(rsa);
        EVP_PKEY_free(key);
        return false;
    }
    RSA_free(rsa);

    PKCS12 *pkcs12 = PKCS12_create(
        password,
        "ADB TV",
        key,
        certificate,
        nullptr,
        NID_aes_256_cbc,
        NID_aes_256_cbc,
        PKCS12_DEFAULT_ITER,
        PKCS12_DEFAULT_ITER,
        0
    );
    X509_free(certificate);
    EVP_PKEY_free(key);
    if (pkcs12 == nullptr) {
        return false;
    }

    int encoded_length = i2d_PKCS12(pkcs12, nullptr);
    bool can_encode = encoded_length > 0
        && static_cast<size_t>(encoded_length) <= output_capacity;
    if (can_encode) {
        uint8_t *cursor = output_pkcs12_der;
        can_encode = i2d_PKCS12(pkcs12, &cursor) == encoded_length;
    }
    PKCS12_free(pkcs12);

    if (!can_encode) {
        return false;
    }

    *output_pkcs12_der_length = static_cast<size_t>(encoded_length);
    return true;
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
