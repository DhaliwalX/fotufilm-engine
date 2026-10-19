package com.muastudio.fotufilm.flutter

import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/** The editor (lib/) in Flutter's activity, with the engine's films unpacked before Dart starts. */
class MainActivity : FlutterActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        EngineResources.prepare(this)
        super.onCreate(savedInstanceState)
    }
}
