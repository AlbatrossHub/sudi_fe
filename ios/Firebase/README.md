Per-flavor Firebase config. Put each flavor's GoogleService-Info.plist in the
folder named after its bundle id; a build phase copies the right one into the
app. A missing plist is skipped (the app then runs with push disabled).
