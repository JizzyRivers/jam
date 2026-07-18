package com.jam.bt;

import android.app.Service;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.IBinder;
import android.util.Log;

// Headless Bluetooth scan/pair driver -- no UI, since the Echo has no
// screen anyway. jam.sh drives this entirely via `am broadcast` into
// JamBtReceiver; everything this service does gets logged with tag "JamBT"
// so `adb logcat -s JamBT:*` is the read side of the interface.
public class JamBtService extends Service {
    private static final String TAG = "JamBT";
    private BroadcastReceiver btReceiver;
    private BluetoothAdapter adapter;

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
                    boolean bondStarted = device.createBond();
                    Log.i(TAG, "PAIR_START: " + mac + " -> " + bondStarted);
                } catch (IllegalArgumentException e) {
                    Log.i(TAG, "ERROR: invalid mac " + mac);
                }
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
