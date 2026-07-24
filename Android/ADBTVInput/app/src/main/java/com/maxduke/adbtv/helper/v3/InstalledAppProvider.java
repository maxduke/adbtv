package com.maxduke.adbtv.helper.v3;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.os.Build;
import android.os.ParcelFileDescriptor;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;

public final class InstalledAppProvider extends ContentProvider {
    private static final String APPS_PATH = "apps";
    private static final int ICON_SIZE = 96;
    private static final int MAX_PNG_BYTE_COUNT = 48 * 1024;
    private static final int MAX_TEXT_CODE_POINTS = 256;

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)
                || uri.getPathSegments().size() != 1
                || !APPS_PATH.equals(uri.getPathSegments().get(0))) {
            throw new FileNotFoundException("Unsupported app request");
        }

        final List<String> packageNames;
        try {
            packageNames = InstalledAppRequest.parsePackageNames(uri.getQueryParameter("packages"));
        } catch (IllegalArgumentException error) {
            throw new FileNotFoundException(error.getMessage());
        }

        ParcelFileDescriptor[] pipe;
        try {
            pipe = ParcelFileDescriptor.createPipe();
        } catch (IOException error) {
            throw new FileNotFoundException("Could not create app response");
        }

        ParcelFileDescriptor writeSide = pipe[1];
        new Thread(
                () -> writeResponse(writeSide, packageNames),
                "ADBTV-app-provider"
        ).start();
        return pipe[0];
    }

    private void writeResponse(ParcelFileDescriptor output, List<String> packageNames) {
        try (ParcelFileDescriptor.AutoCloseOutputStream stream =
                     new ParcelFileDescriptor.AutoCloseOutputStream(output)) {
            stream.write(appResponse(packageNames).getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {
            // The ADB reader may have cancelled or reached its output limit.
        }
    }

    private String appResponse(List<String> packageNames) {
        JSONArray response = new JSONArray();
        PackageManager packageManager = getContext().getPackageManager();

        for (String packageName : packageNames) {
            try {
                PackageInfo packageInfo = packageManager.getPackageInfo(packageName, 0);
                ApplicationInfo applicationInfo = packageInfo.applicationInfo;
                JSONObject item = new JSONObject();
                item.put("package", packageName);
                item.put("label", boundedText(
                        packageManager.getApplicationLabel(applicationInfo).toString()
                ));
                if (packageInfo.versionName != null) {
                    item.put("versionName", boundedText(packageInfo.versionName));
                }
                item.put("versionCode", versionCode(packageInfo));
                item.put("firstInstallTime", packageInfo.firstInstallTime);
                item.put("lastUpdateTime", packageInfo.lastUpdateTime);
                item.put("stopped", (applicationInfo.flags & ApplicationInfo.FLAG_STOPPED) != 0);
                item.put("apkBytes", apkByteCount(
                        applicationInfo.sourceDir,
                        applicationInfo.splitSourceDirs
                ));

                byte[] png = renderIcon(packageManager.getApplicationIcon(applicationInfo));
                if (png != null) {
                    item.put("png", Base64.encodeToString(png, Base64.NO_WRAP));
                }
                response.put(item);
            } catch (Exception ignored) {
                // One missing or malformed app must not fail the batch.
            }
        }
        return response.toString();
    }

    static String boundedText(String value) {
        int codePointCount = value.codePointCount(0, value.length());
        if (codePointCount <= MAX_TEXT_CODE_POINTS) {
            return value;
        }
        return value.substring(0, value.offsetByCodePoints(0, MAX_TEXT_CODE_POINTS));
    }

    static long apkByteCount(String sourceDir, String[] splitSourceDirs) {
        long total = fileByteCount(sourceDir);
        if (splitSourceDirs != null) {
            for (String path : splitSourceDirs) {
                long byteCount = fileByteCount(path);
                total = Long.MAX_VALUE - total < byteCount ? Long.MAX_VALUE : total + byteCount;
            }
        }
        return total;
    }

    @SuppressWarnings("deprecation")
    private static long versionCode(PackageInfo packageInfo) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return packageInfo.getLongVersionCode();
        }
        return packageInfo.versionCode;
    }

    private static long fileByteCount(String path) {
        return path == null ? 0 : Math.max(0, new File(path).length());
    }

    private byte[] renderIcon(Drawable drawable) {
        Bitmap bitmap = Bitmap.createBitmap(ICON_SIZE, ICON_SIZE, Bitmap.Config.ARGB_8888);
        try {
            Canvas canvas = new Canvas(bitmap);
            drawable.setBounds(0, 0, ICON_SIZE, ICON_SIZE);
            drawable.draw(canvas);

            ByteArrayOutputStream output = new ByteArrayOutputStream();
            if (!bitmap.compress(Bitmap.CompressFormat.PNG, 100, output)) {
                return null;
            }
            byte[] png = output.toByteArray();
            return png.length <= MAX_PNG_BYTE_COUNT ? png : null;
        } finally {
            bitmap.recycle();
        }
    }

    @Override
    public String getType(Uri uri) {
        return "application/json";
    }

    @Override
    public Cursor query(Uri uri, String[] projection, String selection,
                        String[] selectionArgs, String sortOrder) {
        return null;
    }

    @Override
    public Uri insert(Uri uri, ContentValues values) {
        throw new UnsupportedOperationException("Read only");
    }

    @Override
    public int delete(Uri uri, String selection, String[] selectionArgs) {
        throw new UnsupportedOperationException("Read only");
    }

    @Override
    public int update(Uri uri, ContentValues values, String selection,
                      String[] selectionArgs) {
        throw new UnsupportedOperationException("Read only");
    }
}
