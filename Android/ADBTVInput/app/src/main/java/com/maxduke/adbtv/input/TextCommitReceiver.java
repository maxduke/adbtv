package com.maxduke.adbtv.input;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

public final class TextCommitReceiver extends BroadcastReceiver {
    static final String ACTION_COMMIT_TEXT = "com.maxduke.adbtv.input.COMMIT_TEXT";
    static final String EXTRA_TEXT_BASE64 = "text_base64";

    @Override
    public void onReceive(Context context, Intent intent) {
        if (!ACTION_COMMIT_TEXT.equals(intent.getAction())) {
            setResultCode(ADBTVInputMethodService.CommitResult.INVALID_PAYLOAD.code);
            return;
        }

        try {
            String text = TextPayload.decode(intent.getStringExtra(EXTRA_TEXT_BASE64));
            ADBTVInputMethodService.CommitResult result =
                    ADBTVInputMethodService.commitText(text);
            setResultCode(result.code);
            setResultData(result.name());
        } catch (IllegalArgumentException error) {
            setResultCode(ADBTVInputMethodService.CommitResult.INVALID_PAYLOAD.code);
            setResultData(error.getMessage());
        }
    }
}
