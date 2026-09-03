/*
 * Vala bindings for libwebkitgtk-6.0-webdriver extensions.
 * Use: --pkg=webkitgtk-6.0 --pkg=webkitgtk-webdriver
 */

[CCode (cheader_filename = "WebKitNavigatorWebDriverActivePolicy.h", cprefix = "WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_", type_id = "webkit_navigator_webdriver_active_policy_get_type ()")]
namespace WebKit {
    public enum NavigatorWebDriverActivePolicy {
        AUTO,
        ENABLED,
        DISABLED
    }

    public partial class Settings {
        public NavigatorWebDriverActivePolicy navigator_webdriver_active_policy {
            get {
                return webkit_settings_get_navigator_webdriver_active_policy (this);
            }
            set {
                webkit_settings_set_navigator_webdriver_active_policy (this, value);
            }
        }
    }

    [CCode (cheader_filename = "WebKitNavigatorWebDriverActivePolicy.h")]
    public extern NavigatorWebDriverActivePolicy webkit_settings_get_navigator_webdriver_active_policy (Settings settings);

    [CCode (cheader_filename = "WebKitNavigatorWebDriverActivePolicy.h")]
    public extern void webkit_settings_set_navigator_webdriver_active_policy (Settings settings, NavigatorWebDriverActivePolicy policy);
}
