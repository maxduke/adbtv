package com.maxduke.adbtv.helper.v2;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertThrows;

import org.junit.Test;

import java.util.Arrays;
import java.util.stream.Collectors;
import java.util.stream.IntStream;

public final class AppIconRequestTest {
    @Test
    public void parsesValidPackagesAndRemovesDuplicates() {
        assertEquals(
                Arrays.asList("com.example.player", "tv.example_app"),
                AppIconRequest.parsePackageNames(
                        "com.example.player,tv.example_app,com.example.player"
                )
        );
    }

    @Test
    public void rejectsMissingMalformedAndOversizedRequests() {
        assertThrows(
                IllegalArgumentException.class,
                () -> AppIconRequest.parsePackageNames(null)
        );
        assertThrows(
                IllegalArgumentException.class,
                () -> AppIconRequest.parsePackageNames("com.example;reboot")
        );

        String packages = IntStream.range(0, AppIconRequest.MAX_PACKAGE_COUNT + 1)
                .mapToObj(index -> "com.example.app" + index)
                .collect(Collectors.joining(","));
        assertThrows(
                IllegalArgumentException.class,
                () -> AppIconRequest.parsePackageNames(packages)
        );
    }
}
