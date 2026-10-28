# vivo_badge

The number on the app's icon on Vivo / iQOO phones. Vivo's launcher (`com.bbk.launcher2`, `com.vivo.launcher`) takes it
from its own broadcast, `launcher.action.CHANGE_APPLICATION_NOTIFICATION_NUM`; `app_badge_plus` only sends it when the
launcher is `com.vivo.launcher`, which most current Vivo phones don't use. Does nothing on other phones.
The phone must allow it: Settings → Notifications & status bar → App icon badges → this app → on.
