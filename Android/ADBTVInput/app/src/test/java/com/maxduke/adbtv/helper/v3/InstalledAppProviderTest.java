package com.maxduke.adbtv.helper.v3;

import static org.junit.Assert.assertEquals;

import org.junit.Test;

import java.nio.file.Files;
import java.nio.file.Path;

public final class InstalledAppProviderTest {
    @Test
    public void boundsTextWithoutSplittingUnicodeCodePoints() {
        String value = "a".repeat(255) + "\uD83D\uDCFA" + "ignored";

        assertEquals("a".repeat(255) + "\uD83D\uDCFA", InstalledAppProvider.boundedText(value));
    }

    @Test
    public void sumsBaseAndSplitAPKBytes() throws Exception {
        Path directory = Files.createTempDirectory("adbtv-helper-test");
        Path base = Files.write(directory.resolve("base.apk"), new byte[3]);
        Path split = Files.write(directory.resolve("split.apk"), new byte[5]);

        assertEquals(
                8,
                InstalledAppProvider.apkByteCount(
                        base.toString(),
                        new String[] {split.toString(), directory.resolve("missing.apk").toString()}
                )
        );
    }
}
