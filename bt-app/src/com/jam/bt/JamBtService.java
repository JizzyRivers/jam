package com.jam.bt;

import android.app.Service;
import android.bluetooth.BluetoothA2dp;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothProfile;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.IBinder;
import android.util.Log;

import java.lang.reflect.Method;

// Headless Bluetooth scan/pair/connect driver -- no UI, since the Echo has
// no screen anyway. jam.sh drives this entirely via `am startservice`;
// everything this service does gets logged with tag "JamBT" so
// `adb logcat -s JamBT:*` is the read side of the interface.
public class JamBtService extends Service {
    private static final String TAG = "JamBT";
    private BroadcastReceiver btReceiver;
    private BluetoothAdapter adapter;
    private BluetoothA2dp a2dp;

    // BluetoothA2dp.connect(BluetoothDevice) is @hide in the public SDK --
    // createBond() alone bonds a device but does NOT connect the A2DP audio
    // profile (confirmed live: dumpsys bluetooth_manager showed
    // mCurrentDevice: null after a successful bond). System apps get this
    // method directly; a normal sideloaded app needs reflection instead.
    // Fine here since this Android version (API 22) predates the
    // hidden-API enforcement introduced in API 28.
    private void connectA2dp(final BluetoothDevice device) {
        adapter.getProfileProxy(this, new BluetoothProfile.ServiceListener() {
            @Override
            public void onServiceConnected(int profile, BluetoothProfile proxy) {
                if (profile != BluetoothProfile.A2DP) {
                    return;
                }
                a2dp = (BluetoothA2dp) proxy;
                try {
                    Method connect = BluetoothA2dp.class.getMethod("connect", BluetoothDevice.class);
                    Object result = connect.invoke(a2dp, device);
                    Log.i(TAG, "A2DP_CONNECT: " + device.getAddress() + " -> " + result);
                } catch (Exception e) {
                    Log.i(TAG, "ERROR: A2DP connect reflection failed: " + e);
                }
            }

            @Override
            public void onServiceDisconnected(int profile) {
            }
        }, BluetoothProfile.A2DP);
    }

    @Override
    public void onCreate() {
        super.onCreate();
        adapter = BluetoothAdapter.getDefaultAdapter();
        btReceiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context context, Intent intent) {
                String action = intent.getAction();
                if (BluetoothDevice.ACTION_FOUND.equals(action)) {
                    BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                    short rssi = intent.getShortExtra(BluetoothDevice.EXTRA_RSSI, Short.MIN_VALUE);
                    String name = device.getName();
                    Log.i(TAG, "FOUND: " + device.getAddress() + " name=" + (name != null ? name : "?") + " rssi=" + rssi);
                } else if (BluetoothAdapter.ACTION_DISCOVERY_FINISHED.equals(action)) {
                    Log.i(TAG, "SCAN_DONE");
                } else if (BluetoothDevice.ACTION_BOND_STATE_CHANGED.equals(action)) {
                    BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                    int state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR);
                    String stateStr;
                    if (state == BluetoothDevice.BOND_BONDED) {
                        stateStr = "BONDED";
                    } else if (state == BluetoothDevice.BOND_BONDING) {
                        stateStr = "BONDING";
                    } else if (state == BluetoothDevice.BOND_NONE) {
                        stateStr = "NONE";
                    } else {
                        stateStr = "UNKNOWN(" + state + ")";
                    }
                    Log.i(TAG, "BOND_STATE: " + device.getAddress() + " -> " + stateStr);
                    if (state == BluetoothDevice.BOND_BONDED) {
                        // Bonding alone doesn't connect the audio profile --
                        // confirmed live (dumpsys showed mCurrentDevice: null
                        // right after a successful bond). Connect it now so
                        // "pair" actually results in usable audio, not just
                        // a bond with silence.
                        connectA2dp(device);
                    }
                } else if (BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED.equals(action)) {
                    BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                    int state = intent.getIntExtra(BluetoothProfile.EXTRA_STATE, -1);
                    String stateStr;
                    if (state == BluetoothProfile.STATE_CONNECTED) {
                        stateStr = "CONNECTED";
                    } else if (state == BluetoothProfile.STATE_CONNECTING) {
                        stateStr = "CONNECTING";
                    } else if (state == BluetoothProfile.STATE_DISCONNECTED) {
                        stateStr = "DISCONNECTED";
                    } else {
                        stateStr = "UNKNOWN(" + state + ")";
                    }
                    Log.i(TAG, "A2DP_STATE: " + (device != null ? device.getAddress() : "?") + " -> " + stateStr);
                } else if ("android.bluetooth.device.action.PAIRING_REQUEST".equals(action)) {
                    // Logged only, not auto-confirmed: setPairingConfirmation()
                    // needs BLUETOOTH_PRIVILEGED, a signature|privileged
                    // permission a normal sideloaded app can't hold. Most A2DP
                    // speakers use Just Works SSP and never hit this at all;
                    // if a specific device does need it, this app would need
                    // to be pushed to /system/priv-app instead (root allows
                    // that, just not attempted here).
                    BluetoothDevice device = intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE);
                    Log.i(TAG, "PAIRING_REQUEST (needs manual confirmation, unhandled): "
                            + (device != null ? device.getAddress() : "?"));
                }
            }
        };
        IntentFilter filter = new IntentFilter();
        filter.addAction(BluetoothDevice.ACTION_FOUND);
        filter.addAction(BluetoothAdapter.ACTION_DISCOVERY_FINISHED);
        filter.addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED);
        filter.addAction(BluetoothA2dp.ACTION_CONNECTION_STATE_CHANGED);
        filter.addAction("android.bluetooth.device.action.PAIRING_REQUEST");
        registerReceiver(btReceiver, filter);
    }

    @Override
    public int onStartCommand(Intent intent, int flags, int startId) {
        if (intent == null || intent.getAction() == null) {
            return START_NOT_STICKY;
        }
        String action = intent.getAction();
        Log.i(TAG, "ACTION: " + action);
        if (adapter == null) {
            Log.i(TAG, "ERROR: no bluetooth adapter");
            return START_NOT_STICKY;
        }
        if (!adapter.isEnabled()) {
            Log.i(TAG, "ERROR: adapter disabled");
            return START_NOT_STICKY;
        }
        if ("com.jam.bt.SCAN".equals(action)) {
            if (adapter.isDiscovering()) {
                adapter.cancelDiscovery();
            }
            boolean started = adapter.startDiscovery();
            Log.i(TAG, "SCAN_START: " + started);
        } else if ("com.jam.bt.CANCEL".equals(action)) {
            boolean cancelled = adapter.cancelDiscovery();
            Log.i(TAG, "SCAN_CANCEL: " + cancelled);
        } else if ("com.jam.bt.PAIR".equals(action)) {
            String mac = intent.getStringExtra("mac");
            if (mac == null) {
                Log.i(TAG, "ERROR: no mac provided");
            } else {
                try {
                    BluetoothDevice device = adapter.getRemoteDevice(mac);
                    if (adapter.isDiscovering()) {
                        adapter.cancelDiscovery();
                    }
                    if (device.getBondState() == BluetoothDevice.BOND_BONDED) {
                        // Already bonded (e.g. re-pairing after the speaker
                        // was power-cycled) -- createBond() won't fire a new
                        // BOND_STATE_CHANGED event since the state isn't
                        // actually changing, so the auto-connect-after-bond
                        // path above would never trigger. Connect directly.
                        Log.i(TAG, "PAIR_START: " + mac + " -> already bonded, connecting A2DP directly");
                        connectA2dp(device);
                    } else {
                        boolean bondStarted = device.createBond();
                        Log.i(TAG, "PAIR_START: " + mac + " -> " + bondStarted);
                    }
                } catch (IllegalArgumentException e) {
                    Log.i(TAG, "ERROR: invalid mac " + mac);
                }
            }
        } else if ("com.jam.bt.PLAY_TEST".equals(action)) {
            // Plays Android's own default notification sound -- a real,
            // guaranteed-valid audio resource bundled with the OS, so this
            // doesn't depend on any of Jam's own earcon files (several of
            // which are now deliberately silenced) or worry about raw .pcm
            // files needing a MediaPlayer-compatible container. Follows
            // whatever audio route is currently active, same as any other
            // app's audio would.
            try {
                android.net.Uri uri = android.media.RingtoneManager.getDefaultUri(android.media.RingtoneManager.TYPE_NOTIFICATION);
                android.media.Ringtone ringtone = android.media.RingtoneManager.getRingtone(getApplicationContext(), uri);
                if (ringtone != null) {
                    ringtone.play();
                    Log.i(TAG, "PLAY_TEST: playing default notification sound");
                } else {
                    Log.i(TAG, "ERROR: could not obtain a ringtone for the default notification sound");
                }
            } catch (Exception e) {
                Log.i(TAG, "ERROR: PLAY_TEST failed: " + e);
            }
        } else {
            Log.i(TAG, "ERROR: unknown action " + action);
        }
        return START_NOT_STICKY;
    }

    @Override
    public IBinder onBind(Intent intent) {
        return null;
    }

    @Override
    public void onDestroy() {
        super.onDestroy();
        if (btReceiver != null) {
            unregisterReceiver(btReceiver);
        }
    }
}
