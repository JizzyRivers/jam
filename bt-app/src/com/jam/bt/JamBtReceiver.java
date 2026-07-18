package com.jam.bt;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;

// Static entry point (registered in the manifest) so `am broadcast -a
// com.jam.bt.SCAN` etc from adb shell can reach the app at all. Just hands
// off to JamBtService immediately, since a BroadcastReceiver has to finish
// onReceive() fast and can't hold a live Bluetooth discovery/pairing
// session open by itself.
public class JamBtReceiver extends BroadcastReceiver {
    @Override
    public void onReceive(Context context, Intent intent) {
        Intent svc = new Intent(context, JamBtService.class);
        svc.setAction(intent.getAction());
        if (intent.getExtras() != null) {
            svc.putExtras(intent.getExtras());
        }
        context.startService(svc);
    }
}
