/*
 * Vala bindings for libwebkitgtk-6.0-webdriver extensions.
 * Use: --pkg=webkitgtk-6.0 --pkg=webkitgtk-webdriver
 */

namespace WebKit {
    [CCode (cheader_filename = "WebKitNavigatorWebDriverActivePolicy.h", cname = "WebKitNavigatorWebdriverActivePolicy", cprefix = "WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_", type_id = "webkit_navigator_webdriver_active_policy_get_type ()")]
    public enum NavigatorWebDriverActivePolicy {
        AUTO,
        ENABLED,
        DISABLED
    }

    [CCode (cheader_filename = "WebKitNavigatorWebDriverActivePolicy.h", cname = "webkit_settings_get_navigator_webdriver_active_policy")]
    public extern NavigatorWebDriverActivePolicy get_navigator_webdriver_active_policy (Settings settings);

    [CCode (cheader_filename = "WebKitNavigatorWebDriverActivePolicy.h", cname = "webkit_settings_set_navigator_webdriver_active_policy")]
    public extern void set_navigator_webdriver_active_policy (Settings settings, NavigatorWebDriverActivePolicy policy);
}
