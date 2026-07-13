package com.maxduke.adbtv.input;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

public final class TextPayloadTest {
    @Test
    public void decodesUtf8Text() {
        assertEquals("你好 Android TV", TextPayload.decode("5L2g5aW9IEFuZHJvaWQgVFY="));
    }

    @Test
    public void rejectsMissingAndMalformedPayloads() {
        assertThrows(IllegalArgumentException.class, () -> TextPayload.decode(null));
        assertThrows(IllegalArgumentException.class, () -> TextPayload.decode("not base64"));
    }
}
