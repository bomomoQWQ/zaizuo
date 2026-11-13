package dev.zaizuo.zaizuo_mobile_probe;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Minimal Android bridge: private files root and bounded Storage Access picker.
 * No broad storage permission, persistent URI grant, networking or Git process. */
public class MainActivity extends FlutterActivity {
    private static final int PICK_IMAGE = 5021;
    private static final int MAX_BYTES = 8 * 1024 * 1024;
    private final ExecutorService reader = Executors.newSingleThreadExecutor();
    private final Handler main = new Handler(Looper.getMainLooper());
    private MethodChannel.Result pending;

    @Override
    public void configureFlutterEngine(@NonNull FlutterEngine engine) {
        super.configureFlutterEngine(engine);
        new MethodChannel(engine.getDartExecutor().getBinaryMessenger(), "zaizuo.mobile_probe/native")
            .setMethodCallHandler((call, result) -> {
                if (call.method.equals("environment")) {
                    Map<String, Object> values = new HashMap<>();
                    values.put("privateRoot", new java.io.File(getNoBackupFilesDir(), "probe").getAbsolutePath());
                    values.put("sdk", Build.VERSION.SDK_INT);
                    values.put("abi", Build.SUPPORTED_ABIS.length == 0 ? "unknown" : Build.SUPPORTED_ABIS[0]);
                    result.success(values);
                } else if (call.method.equals("pickImage")) {
                    if (pending != null) { result.error("picker_busy", "Picker busy", null); return; }
                    Intent intent = new Intent(Intent.ACTION_OPEN_DOCUMENT);
                    intent.addCategory(Intent.CATEGORY_OPENABLE);
                    intent.setType("image/*");
                    intent.putExtra(Intent.EXTRA_MIME_TYPES, new String[]{"image/png", "image/jpeg", "image/webp"});
                    pending = result;
                    try { startActivityForResult(intent, PICK_IMAGE); }
                    catch (Exception ignored) { pending = null; result.error("picker_unavailable", "No document picker", null); }
                } else { result.notImplemented(); }
            });
    }

    @Override
    protected void onActivityResult(int requestCode, int resultCode, Intent data) {
        super.onActivityResult(requestCode, resultCode, data);
        if (requestCode != PICK_IMAGE || pending == null) return;
        final MethodChannel.Result result = pending;
        if (resultCode != Activity.RESULT_OK || data == null || data.getData() == null) {
            pending = null;
            result.success(null);
            return;
        }
        final Uri uri = data.getData();
        // ContentProvider URIs are capabilities; never turn the display name or
        // URI text into an arbitrary filesystem path or log it.
        if (!"content".equals(uri.getScheme())) {
            pending = null;
            result.error("input_unreadable", "Content URI required", null);
            return;
        }
        reader.execute(() -> {
            try (InputStream stream = getContentResolver().openInputStream(uri)) {
                if (stream == null) throw new java.io.IOException();
                ByteArrayOutputStream bytes = new ByteArrayOutputStream();
                byte[] chunk = new byte[16 * 1024];
                int count;
                while ((count = stream.read(chunk)) != -1) {
                    if (count == 0) continue;
                    if (bytes.size() > MAX_BYTES - count) {
                        main.post(() -> finishError(result, "input_limit"));
                        return;
                    }
                    bytes.write(chunk, 0, count);
                }
                byte[] value = bytes.toByteArray();
                main.post(() -> {
                    if (pending == result) { pending = null; result.success(value); }
                });
            } catch (Exception ignored) {
                main.post(() -> finishError(result, "input_unreadable"));
            }
        });
    }

    private void finishError(MethodChannel.Result result, String code) {
        if (pending == result) { pending = null; result.error(code, "Image input rejected", null); }
    }

    @Override
    protected void onDestroy() {
        if (pending != null) {
            pending.error("native_failure", "Activity closed", null);
            pending = null;
        }
        reader.shutdownNow();
        super.onDestroy();
    }
}
