#include "CADBPairingCrypto.h"

#include <openssl/curve25519.h>
#include <openssl/evp.h>
#include <openssl/obj.h>
#include <openssl/pem.h>
#include <openssl/pkcs8.h>
#include <openssl/rsa.h>
#include <openssl/ssl.h>
#include <openssl/x509.h>
#include <openssl/x509v3.h>

#include <stdlib.h>
#include <string.h>

#include <limits.h>

#include <vector>

struct ADBPairingCryptoContext {
    SPAKE2_CTX *spake2;
    uint8_t message[ADB_PAIRING_CRYPTO_MESSAGE_BYTE_COUNT];
    size_t message_length;
    bool did_process_message;
};

struct ADBTLSContext {
    SSL_CTX *ssl_context;
    SSL *ssl;
    BIO *encrypted_input;
    BIO *encrypted_output;
    bool handshake_complete;
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

static int accept_peer_certificate(int, X509_STORE_CTX *) {
    return 1;
}

static int select_configured_certificate(SSL *, void *) {
    return 1;
}

static ADBTLSResult classify_tls_result(ADBTLSContext *context, int result) {
    if (context == nullptr || context->ssl == nullptr) {
        return ADB_TLS_RESULT_ERROR;
    }
    if (result > 0) {
        return ADB_TLS_RESULT_COMPLETE;
    }

    switch (SSL_get_error(context->ssl, result)) {
        case SSL_ERROR_WANT_READ:
            return ADB_TLS_RESULT_WANT_READ;
        case SSL_ERROR_WANT_WRITE:
            return ADB_TLS_RESULT_WANT_WRITE;
        case SSL_ERROR_ZERO_RETURN:
            return ADB_TLS_RESULT_CLOSED;
        default:
            return ADB_TLS_RESULT_ERROR;
    }
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
        0,
        0,
        0,
        0,
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

ADBTLSContext *adb_tls_create(
    ADBTLSRole role,
    const uint8_t *certificate_pem,
    size_t certificate_pem_length,
    const uint8_t *private_key_pem,
    size_t private_key_pem_length
) {
    if ((role != ADB_TLS_ROLE_CLIENT && role != ADB_TLS_ROLE_SERVER) ||
        certificate_pem == nullptr || certificate_pem_length == 0 ||
        certificate_pem_length > INT_MAX || private_key_pem == nullptr ||
        private_key_pem_length == 0 || private_key_pem_length > INT_MAX) {
        return nullptr;
    }

    BIO *certificate_bio = BIO_new_mem_buf(
        certificate_pem,
        static_cast<int>(certificate_pem_length)
    );
    BIO *private_key_bio = BIO_new_mem_buf(
        private_key_pem,
        static_cast<int>(private_key_pem_length)
    );
    X509 *certificate = certificate_bio == nullptr
        ? nullptr
        : PEM_read_bio_X509(certificate_bio, nullptr, nullptr, nullptr);
    EVP_PKEY *private_key = private_key_bio == nullptr
        ? nullptr
        : PEM_read_bio_PrivateKey(private_key_bio, nullptr, nullptr, nullptr);
    BIO_free(certificate_bio);
    BIO_free(private_key_bio);
    if (certificate == nullptr || private_key == nullptr) {
        X509_free(certificate);
        EVP_PKEY_free(private_key);
        return nullptr;
    }

    SSL_CTX *ssl_context = SSL_CTX_new(TLS_method());
    bool configured = ssl_context != nullptr
        && SSL_CTX_set_min_proto_version(ssl_context, TLS1_3_VERSION) == 1
        && SSL_CTX_set_max_proto_version(ssl_context, TLS1_3_VERSION) == 1
        && SSL_CTX_use_certificate(ssl_context, certificate) == 1
        && SSL_CTX_use_PrivateKey(ssl_context, private_key) == 1
        && SSL_CTX_check_private_key(ssl_context) == 1;
    X509_free(certificate);
    EVP_PKEY_free(private_key);
    if (!configured) {
        SSL_CTX_free(ssl_context);
        return nullptr;
    }

    if (role == ADB_TLS_ROLE_SERVER) {
        SSL_CTX_set_verify(
            ssl_context,
            SSL_VERIFY_PEER | SSL_VERIFY_FAIL_IF_NO_PEER_CERT,
            accept_peer_certificate
        );
    } else {
        SSL_CTX_set_verify(ssl_context, SSL_VERIFY_NONE, nullptr);
        SSL_CTX_set_cert_cb(ssl_context, select_configured_certificate, nullptr);
    }

    SSL *ssl = SSL_new(ssl_context);
    BIO *encrypted_input = BIO_new(BIO_s_mem());
    BIO *encrypted_output = BIO_new(BIO_s_mem());
    if (ssl == nullptr || encrypted_input == nullptr || encrypted_output == nullptr) {
        SSL_free(ssl);
        BIO_free(encrypted_input);
        BIO_free(encrypted_output);
        SSL_CTX_free(ssl_context);
        return nullptr;
    }
    BIO_set_mem_eof_return(encrypted_input, -1);
    BIO_set_mem_eof_return(encrypted_output, -1);
    SSL_set_bio(ssl, encrypted_input, encrypted_output);
    if (role == ADB_TLS_ROLE_SERVER) {
        SSL_set_accept_state(ssl);
    } else {
        SSL_set_connect_state(ssl);
    }

    ADBTLSContext *context = static_cast<ADBTLSContext *>(calloc(1, sizeof(ADBTLSContext)));
    if (context == nullptr) {
        SSL_free(ssl);
        SSL_CTX_free(ssl_context);
        return nullptr;
    }
    context->ssl_context = ssl_context;
    context->ssl = ssl;
    context->encrypted_input = encrypted_input;
    context->encrypted_output = encrypted_output;
    return context;
}

ADBTLSResult adb_tls_handshake(ADBTLSContext *context) {
    if (context == nullptr || context->ssl == nullptr) {
        return ADB_TLS_RESULT_ERROR;
    }
    if (context->handshake_complete) {
        return ADB_TLS_RESULT_COMPLETE;
    }

    int result = SSL_do_handshake(context->ssl);
    ADBTLSResult classified = classify_tls_result(context, result);
    if (classified == ADB_TLS_RESULT_COMPLETE) {
        context->handshake_complete = true;
    }
    return classified;
}

bool adb_tls_provide_encrypted_input(
    ADBTLSContext *context,
    const uint8_t *bytes,
    size_t byte_count
) {
    if (context == nullptr || context->encrypted_input == nullptr ||
        (bytes == nullptr && byte_count > 0) || byte_count > INT_MAX) {
        return false;
    }

    size_t offset = 0;
    while (offset < byte_count) {
        int written = BIO_write(
            context->encrypted_input,
            bytes + offset,
            static_cast<int>(byte_count - offset)
        );
        if (written <= 0) {
            return false;
        }
        offset += static_cast<size_t>(written);
    }
    return true;
}

size_t adb_tls_pending_encrypted_output(const ADBTLSContext *context) {
    if (context == nullptr || context->encrypted_output == nullptr) {
        return 0;
    }

    return BIO_ctrl_pending(context->encrypted_output);
}

bool adb_tls_copy_encrypted_output(
    ADBTLSContext *context,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_byte_count
) {
    if (context == nullptr || context->encrypted_output == nullptr || output == nullptr ||
        output_byte_count == nullptr || output_capacity > INT_MAX) {
        return false;
    }
    *output_byte_count = 0;

    size_t pending = adb_tls_pending_encrypted_output(context);
    if (pending == 0) {
        return true;
    }
    if (pending > output_capacity || pending > INT_MAX) {
        return false;
    }

    int read = BIO_read(context->encrypted_output, output, static_cast<int>(pending));
    if (read <= 0 || static_cast<size_t>(read) != pending) {
        return false;
    }
    *output_byte_count = static_cast<size_t>(read);
    return true;
}

ADBTLSResult adb_tls_write_plaintext(
    ADBTLSContext *context,
    const uint8_t *bytes,
    size_t byte_count,
    size_t *consumed_byte_count
) {
    if (context == nullptr || context->ssl == nullptr || !context->handshake_complete ||
        bytes == nullptr || byte_count == 0 || byte_count > INT_MAX ||
        consumed_byte_count == nullptr) {
        return ADB_TLS_RESULT_ERROR;
    }
    *consumed_byte_count = 0;

    int result = SSL_write(context->ssl, bytes, static_cast<int>(byte_count));
    if (result > 0) {
        *consumed_byte_count = static_cast<size_t>(result);
    }
    return classify_tls_result(context, result);
}

ADBTLSResult adb_tls_read_plaintext(
    ADBTLSContext *context,
    uint8_t *output,
    size_t output_capacity,
    size_t *output_byte_count
) {
    if (context == nullptr || context->ssl == nullptr || !context->handshake_complete ||
        output == nullptr || output_capacity == 0 || output_capacity > INT_MAX ||
        output_byte_count == nullptr) {
        return ADB_TLS_RESULT_ERROR;
    }
    *output_byte_count = 0;

    int result = SSL_read(context->ssl, output, static_cast<int>(output_capacity));
    if (result > 0) {
        *output_byte_count = static_cast<size_t>(result);
    }
    return classify_tls_result(context, result);
}

bool adb_tls_has_peer_certificate(const ADBTLSContext *context) {
    if (context == nullptr || context->ssl == nullptr || !context->handshake_complete) {
        return false;
    }

    X509 *certificate = SSL_get_peer_certificate(context->ssl);
    if (certificate == nullptr) {
        return false;
    }
    X509_free(certificate);
    return true;
}

void adb_tls_destroy(ADBTLSContext *context) {
    if (context == nullptr) {
        return;
    }

    SSL_free(context->ssl);
    SSL_CTX_free(context->ssl_context);
    memset(context, 0, sizeof(ADBTLSContext));
    free(context);
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
