package org.moorbox.hello;

import android.app.Activity;
import android.os.Bundle;
import android.widget.TextView;

/** Minimal app used by Moorbox's integration tests to verify APK install and launch. */
public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        TextView text = new TextView(this);
        text.setText("Hello from Moorbox");
        text.setTextSize(32);
        setContentView(text);
    }
}
