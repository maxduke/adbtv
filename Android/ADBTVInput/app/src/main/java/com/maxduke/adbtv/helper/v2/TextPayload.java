package com.maxduke.adbtv.helper.v2;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

final class TextPayload {
    private TextPayload() {}

    static String decode(String encodedText) {
        if (encodedText == null) {
            throw new IllegalArgumentException("Missing text payload");
        }
        byte[] bytes = Base64.getDecoder().decode(encodedText);
        return new String(bytes, StandardCharsets.UTF_8);
    }
}
