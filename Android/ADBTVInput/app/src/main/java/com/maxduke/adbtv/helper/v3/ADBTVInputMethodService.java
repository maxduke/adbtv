package com.maxduke.adbtv.helper.v3;

import android.inputmethodservice.InputMethodService;
import android.view.inputmethod.InputConnection;

import java.lang.ref.WeakReference;

public final class ADBTVInputMethodService extends InputMethodService {
    private static WeakReference<ADBTVInputMethodService> activeService =
            new WeakReference<>(null);

    @Override
    public void onCreate() {
        super.onCreate();
        activeService = new WeakReference<>(this);
    }

    @Override
    public void onDestroy() {
        if (activeService.get() == this) {
            activeService.clear();
        }
        super.onDestroy();
    }

    static CommitResult commitText(String text) {
        ADBTVInputMethodService service = activeService.get();
        if (service == null) {
            return CommitResult.INPUT_METHOD_NOT_ACTIVE;
        }

        InputConnection connection = service.getCurrentInputConnection();
        if (connection == null) {
            return CommitResult.NO_FOCUSED_TEXT_FIELD;
        }

        return connection.commitText(text, 1)
                ? CommitResult.SUCCESS
                : CommitResult.COMMIT_REJECTED;
    }

    enum CommitResult {
        SUCCESS(0),
        INVALID_PAYLOAD(2),
        INPUT_METHOD_NOT_ACTIVE(3),
        NO_FOCUSED_TEXT_FIELD(4),
        COMMIT_REJECTED(5);

        final int code;

        CommitResult(int code) {
            this.code = code;
        }
    }
}
