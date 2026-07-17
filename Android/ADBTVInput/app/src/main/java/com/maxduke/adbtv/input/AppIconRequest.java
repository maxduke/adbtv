package com.maxduke.adbtv.input;

import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;

final class AppIconRequest {
    static final int MAX_PACKAGE_COUNT = 16;

    private AppIconRequest() {}

    static List<String> parsePackageNames(String value) {
        if (value == null || value.isEmpty()) {
            throw new IllegalArgumentException("Missing packages");
        }

        String[] values = value.split(",", -1);
        if (values.length > MAX_PACKAGE_COUNT) {
            throw new IllegalArgumentException("Too many packages");
        }

        LinkedHashSet<String> packages = new LinkedHashSet<>();
        for (String packageName : values) {
            if (!isValidPackageName(packageName)) {
                throw new IllegalArgumentException("Invalid package name");
            }
            packages.add(packageName);
        }
        return new ArrayList<>(packages);
    }

    private static boolean isValidPackageName(String value) {
        if (value.isEmpty()
                || value.startsWith(".")
                || value.endsWith(".")
                || value.contains("..")) {
            return false;
        }

        for (int index = 0; index < value.length(); index++) {
            char character = value.charAt(index);
            if ((character >= 'a' && character <= 'z')
                    || (character >= 'A' && character <= 'Z')
                    || (character >= '0' && character <= '9')
                    || character == '_'
                    || character == '.') {
                continue;
            }
            return false;
        }
        return true;
    }
}
