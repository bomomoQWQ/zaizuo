package dev.zaizuo.zaizuo_mobile_probe;

import android.app.Activity;
import android.content.Intent;
import android.net.Uri;
import android.os.Build;
import android.os.Handler;
import android.os.Looper;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.DataInputStream;
import java.io.DataOutputStream;
import java.net.URI;
import java.nio.charset.StandardCharsets;
import java.security.KeyStore;
import java.security.MessageDigest;
import java.util.Locale;
import java.util.Arrays;
import javax.crypto.Cipher;
import javax.crypto.KeyGenerator;
import javax.crypto.SecretKey;
import javax.crypto.spec.GCMParameterSpec;
import android.security.keystore.KeyGenParameterSpec;
import android.security.keystore.KeyProperties;
import android.system.Os;
import java.util.HashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import androidx.annotation.NonNull;
import io.flutter.embedding.android.FlutterActivity;
import io.flutter.embedding.engine.FlutterEngine;
import io.flutter.plugin.common.MethodChannel;

/** Minimal Android bridge: private files root and bounded Storage Access picker.
 * No broad storage permission, persistent URI grant or Git subprocess.
 * Git credentials are explicitly supplied and protected by AndroidKeyStore. */
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
                } else if (call.method.equals("gitCredentialSave")
                        || call.method.equals("gitCredentialRead")
                        || call.method.equals("gitCredentialDelete")) {
                    // Serialize all file/key operations off the UI thread. Never
                    // forward exception text: it may include credential input.
                    reader.execute(() -> {
                        try {
                            Object value = gitCredential(call.method, call.argument("repoUrl"),
                                    call.argument("username"), call.argument("token"));
                            main.post(() -> result.success(value));
                        } catch (CredentialFailure failure) {
                            main.post(() -> result.error(failure.code, "Git credential operation failed", null));
                        } catch (Exception ignored) {
                            main.post(() -> result.error("credential_unavailable", "Git credential operation failed", null));
                        }
                    });
                } else { result.notImplemented(); }
            });
    }

    private static final class CredentialFailure extends Exception {
        final String code;
        CredentialFailure(String code) { this.code = code; }
    }

    /** Exact repository scope, not a host-wide credential helper. */
    private static String canonicalRepo(Object value) throws CredentialFailure {
        try {
            if (!(value instanceof String)) throw new Exception();
            String text = (String) value;
            if (text.length() > 4096 || !text.equals(text.trim())) throw new Exception();
            URI uri = new URI(text);
            String host = uri.getHost();
            String path = uri.getRawPath();
            if (!"https".equalsIgnoreCase(uri.getScheme()) || host == null || host.isEmpty()
                    || uri.getRawUserInfo() != null || uri.getRawQuery() != null
                    || uri.getRawFragment() != null || uri.getPort() == 0 || uri.getPort() > 65535
                    || path == null || path.isEmpty() || path.equals("/")
                    || path.matches("(?i).*/(?:\\.|%2e)(?:\\.|%2e)?(?:/.*|$)")
                    || !uri.normalize().getRawPath().equals(path)) throw new Exception();
            // Keep complete escaped path (including .git and trailing slash).
            return "https://" + host.toLowerCase(Locale.ROOT)
                    + (uri.getPort() == -1 || uri.getPort() == 443 ? "" : ":" + uri.getPort()) + path;
        } catch (Exception ignored) { throw new CredentialFailure("credential_invalid_scope"); }
    }

    private Object gitCredential(String method, Object repo, Object user, Object token) throws Exception {
        String canonical = canonicalRepo(repo);
        if (!(user instanceof String) || ((String) user).isEmpty() || ((String) user).length() > 256
                || ((String) user).chars().anyMatch(c -> c < 32 || c == 127))
            throw new CredentialFailure("credential_invalid_scope");
        String username = (String) user;
        // Length-prefix the username to avoid delimiter ambiguity in the AAD.
        byte[] aad = ("zaizuo.git-credential.v1\n" + username.length() + ":" + username + "\n" + canonical)
                .getBytes(StandardCharsets.UTF_8);
        byte[] digest = MessageDigest.getInstance("SHA-256").digest(aad);
        StringBuilder id = new StringBuilder();
        for (byte b : digest) id.append(String.format(Locale.ROOT, "%02x", b & 255));
        String alias = "zaizuo.git.v1." + id;
        File directory = new File(getNoBackupFilesDir(), "git-credentials-v1");
        if (!directory.isDirectory() && !directory.mkdirs()) throw new CredentialFailure("credential_unavailable");
        File blob = new File(directory, id + ".bin");
        File temporary = new File(directory, id + ".tmp");
        KeyStore store = KeyStore.getInstance("AndroidKeyStore");
        store.load(null);
        if (method.equals("gitCredentialDelete")) {
            // unlink is atomic; absence is deliberately idempotent.
            if (blob.exists()) Os.remove(blob.getAbsolutePath());
            if (temporary.exists()) Os.remove(temporary.getAbsolutePath());
            if (store.containsAlias(alias)) store.deleteEntry(alias);
            return null;
        }
        if (method.equals("gitCredentialSave")) {
            if (!(token instanceof String) || ((String) token).isEmpty() || ((String) token).length() > 16384
                    || ((String) token).chars().anyMatch(c -> c < 32 || c == 127))
                throw new CredentialFailure("credential_invalid_input");
            if (!store.containsAlias(alias)) {
                KeyGenerator generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore");
                generator.init(new KeyGenParameterSpec.Builder(alias,
                        KeyProperties.PURPOSE_ENCRYPT | KeyProperties.PURPOSE_DECRYPT)
                        .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                        .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                        .setRandomizedEncryptionRequired(true).setKeySize(256).build());
                generator.generateKey(); // Non-exportable AndroidKeyStore key.
            }
            byte[] clear = ((String) token).getBytes(StandardCharsets.UTF_8);
            try {
                SecretKey key = (SecretKey) store.getKey(alias, null);
                Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
                cipher.init(Cipher.ENCRYPT_MODE, key);
                cipher.updateAAD(aad);
                byte[] ciphertext = cipher.doFinal(clear);
                try (FileOutputStream output = new FileOutputStream(temporary);
                        DataOutputStream data = new DataOutputStream(output)) {
                    data.writeInt(1);
                    data.write(cipher.getIV()); // Provider-generated 12-byte nonce.
                    data.writeInt(ciphertext.length);
                    data.write(ciphertext);
                    data.flush();
                    output.getFD().sync();
                }
                Os.rename(temporary.getAbsolutePath(), blob.getAbsolutePath());
            } finally {
                Arrays.fill(clear, (byte) 0);
                if (temporary.exists()) temporary.delete();
            }
            return null;
        }
        if (!blob.isFile()) throw new CredentialFailure("credential_missing");
        if (!store.containsAlias(alias)) throw new CredentialFailure("credential_invalidated");
        try {
            if (blob.length() < 36 || blob.length() > 65580) throw new Exception();
            byte[] nonce = new byte[12];
            byte[] ciphertext;
            try (DataInputStream data = new DataInputStream(new FileInputStream(blob))) {
                if (data.readInt() != 1) throw new Exception();
                data.readFully(nonce);
                int length = data.readInt();
                if (length < 16 || length > 65552 || blob.length() != 20L + length) throw new Exception();
                ciphertext = new byte[length];
                data.readFully(ciphertext);
            }
            Cipher cipher = Cipher.getInstance("AES/GCM/NoPadding");
            cipher.init(Cipher.DECRYPT_MODE, (SecretKey) store.getKey(alias, null), new GCMParameterSpec(128, nonce));
            cipher.updateAAD(aad);
            byte[] clear = cipher.doFinal(ciphertext);
            try { return new String(clear, StandardCharsets.UTF_8); }
            finally { Arrays.fill(clear, (byte) 0); }
        } catch (android.security.keystore.KeyPermanentlyInvalidatedException ignored) {
            throw new CredentialFailure("credential_invalidated");
        } catch (Exception ignored) {
            throw new CredentialFailure("credential_corrupt");
        }
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
