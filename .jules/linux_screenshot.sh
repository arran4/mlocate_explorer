#!/bin/bash
export DISPLAY=:99
Xvfb :99 -screen 0 1280x800x24 > /dev/null 2>&1 &
XVFB_PID=$!
sleep 2

flutter run -d linux &
APP_PID=$!

# Wait for app to start
sleep 30

import -window root .jules/linux_start.png

kill $APP_PID
kill $XVFB_PID
