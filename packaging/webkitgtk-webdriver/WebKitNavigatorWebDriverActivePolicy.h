/*
 * Extension API shipped by libwebkitgtk-6.0-webdriver-dev for
 * navigator.webdriver policy control (WebKit #165269).
 *
 * Link against libwebkitgtk-6.0-webdriver; keep using system
 * webkitgtk-6.0 headers for the rest of WebKitGTK.
 */
#pragma once

#include <glib-object.h>
#include <webkitgtk-6.0/WebKitSettings.h>

G_BEGIN_DECLS

/**
 * WebKitNavigatorWebdriverActivePolicy:
 * @WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_AUTO: Expose %TRUE for %navigator.webdriver when automation-controlled.
 * @WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_ENABLED: Always expose %TRUE for %navigator.webdriver.
 * @WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_DISABLED: Omit %navigator.webdriver from page JavaScript (invisible; not %FALSE).
 */
typedef enum {
    WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_AUTO,
    WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_ENABLED,
    WEBKIT_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY_DISABLED
} WebKitNavigatorWebdriverActivePolicy;

#define WEBKIT_TYPE_NAVIGATOR_WEBDRIVER_ACTIVE_POLICY (webkit_navigator_webdriver_active_policy_get_type ())

WEBKIT_API GType
webkit_navigator_webdriver_active_policy_get_type (void);

WEBKIT_API WebKitNavigatorWebdriverActivePolicy
webkit_settings_get_navigator_webdriver_active_policy (WebKitSettings *settings);

WEBKIT_API void
webkit_settings_set_navigator_webdriver_active_policy (WebKitSettings *settings,
                                                       WebKitNavigatorWebdriverActivePolicy policy);

G_END_DECLS
