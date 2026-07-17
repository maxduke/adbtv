package com.maxduke.adbtv.input;

import android.content.ContentProvider;
import android.content.ContentValues;
import android.content.pm.PackageManager;
import android.database.Cursor;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.drawable.Drawable;
import android.net.Uri;
import android.os.ParcelFileDescriptor;
import android.util.Base64;

import org.json.JSONArray;
import org.json.JSONObject;

import java.io.ByteArrayOutputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.List;

public final class AppIconProvider extends ContentProvider {
    private static final String ICONS_PATH = "icons";
    private static final int ICON_SIZE = 96;
    private static final int MAX_PNG_BYTE_COUNT = 48 * 1024;

    @Override
    public boolean onCreate() {
        return true;
    }

    @Override
    public ParcelFileDescriptor openFile(Uri uri, String mode) throws FileNotFoundException {
        if (!"r".equals(mode)
                || uri.getPathSegments().size() != 1
                || !ICONS_PATH.equals(uri.getPathSegments().get(0))) {
            throw new FileNotFoundException("Unsupported icon request");
        }

        final List<String> packageNames;
        try {
            packageNames = AppIconRequest.parsePackageNames(uri.getQueryParameter("packages"));
        } catch (IllegalArgumentException error) {
            throw new FileNotFoundException(error.getMessage());
        }

        ParcelFileDescriptor[] pipe;
        try {
            pipe = ParcelFileDescriptor.createPipe();
        } catch (IOException error) {
            throw new FileNotFoundException("Could not create icon response");
        }

        ParcelFileDescriptor writeSide = pipe[1];
        new Thread(
                () -> writeResponse(writeSide, packageNames),
                "ADBTV-icon-provider"
        ).start();
        return pipe[0];
    }

    private void writeResponse(ParcelFileDescriptor output, List<String> packageNames) {
        try (ParcelFileDescriptor.AutoCloseOutputStream stream =
                     new ParcelFileDescriptor.AutoCloseOutputStream(output)) {
            stream.write(iconResponse(packageNames).getBytes(StandardCharsets.UTF_8));
        } catch (IOException ignored) {
            // The ADB reader may have cancelled or reached its output limit.
        }
    }

    private String iconResponse(List<String> packageNames) {
        JSONArray response = new JSONArray();
        PackageManager packageManager = getContext().getPackageManager();

        for (String packageName : packageNames) {
            try {
                byte[] png = renderIcon(packageManager.getApplicationIcon(packageName));
                if (png == null) {
                    continue;
                }
                JSONObject item = new JSONObject();
                item.put("package", packageName);
                item.put("png", Base64.encodeToString(png, Base64.NO_WRAP));
                response.put(item);
            } catch (Exception ignored) {
                // One missing or malformed icon must not fail the batch.
            }
        }
        return response.toString();
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
