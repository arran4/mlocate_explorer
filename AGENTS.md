# Agent Information

* The directory `.jules/` contains scripts used for generating screenshots and GIFs of the application. These scripts use Playwright against a Flutter Web build (`flutter build web`) that relies on a faked node tree to bypass native file picker limitations in the headless browser. These scripts can be reused to regenerate screenshots on subsequent releases.
* Please ensure that any modified scripts and generated images (like those in `assets/`) are included in commits when updating screenshots.
* To regenerate screenshots, you may use the Playwright Python script stored in `.jules/screenshot.py`. Note that since Playwright cannot interact directly with the native file picker via `CanvasKit`, the scripts use a mocked `rootNode` approach by modifying the UI temporarily before capture.
