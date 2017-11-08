/* NS Cocoa part implementation of xwidget and webkit widget.

Copyright (C) 1989, 1992-1994, 2005-2006, 2008-2017 Free Software
Foundation, Inc.

This file is part of GNU Emacs.

GNU Emacs is free software: you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation, either version 3 of the License, or (at
your option) any later version.

GNU Emacs is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with GNU Emacs.  If not, see <http://www.gnu.org/licenses/>.  */

#include <config.h>

#include "lisp.h"
#include "blockinput.h"
#include "dispextern.h"
#include "frame.h"
#include "nsterm.h"
#include "xwidget.h"

/* in xwidget.c */
void store_xwidget_event_string (struct xwidget *xw,
                                 const char *eventname,
                                 const char *eventstr);

void store_xwidget_js_callback_event (struct xwidget *xw,
                                      Lisp_Object proc,
                                      Lisp_Object argument);

#import <AppKit/AppKit.h>
#import <WebKit/WebKit.h>

/* Thoughts on NS Cocoa xwidget and webkit2:

   Webkit2 process architecture seems to be very hostile for offscreen
   rendering techniques, which is used by GTK xwiget implementation;
   Specifically NSView level view sharing / copying is not working.

   *** So only one view can be associcated with a model. ***

   With this decision, implementation is plain and can expect best out
   of webkit2's rationale.  But process and session structures will
   diverge from GTK xwiget.  Though, cosmetically similar usages can
   be presented and will be preferred, if agreeable.

   For other widget types, OSR seems possible, but will not care for a
   while.
*/

/* xwidget webkit */

@interface XwWebView : WKWebView<WKNavigationDelegate, WKUIDelegate>
@property struct xwidget *xw;
@end
@implementation XwWebView : WKWebView

- (id)initWithFrame:(CGRect)frame
      configuration:(WKWebViewConfiguration *)configuration
            xwidget:(struct xwidget *)xw
{
  self = [super initWithFrame:frame configuration:configuration];
  if (self)
    {
      self.xw = xw;
      self.navigationDelegate = self;
      self.UIDelegate = self;
    }
  return self;
}

#if 0
/* Non ARC - just to check lifecycle */
- (void)dealloc
{
  NSLog (@"XwWebView dealloc");
  [super dealloc];
}
#endif

-(void)webView:(WKWebView *)webView
didFinishNavigation:(WKNavigation *)navigation
{
  store_xwidget_event_string (self.xw, "load-changed", "");
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationAction:(WKNavigationAction *)navigationAction
decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler
{
  switch (navigationAction.navigationType) {
  case WKNavigationTypeLinkActivated:
    decisionHandler (WKNavigationActionPolicyAllow);
    break;
  default:
    // decisionHandler (WKNavigationActionPolicyCancel);
    decisionHandler (WKNavigationActionPolicyAllow);
    break;
  }
}

- (void)webView:(WKWebView *)webView
decidePolicyForNavigationResponse:(WKNavigationResponse *)navigationResponse
decisionHandler:(void (^)(WKNavigationResponsePolicy))decisionHandler
{
  if (!navigationResponse.canShowMIMEType)
    {
      // download using NSURLxxx
    }
  decisionHandler (WKNavigationResponsePolicyAllow);
}

/* No new webview or emacs window for <a ... target="_bkank"> */
- (WKWebView *)webView:(WKWebView *)webView
createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
   forNavigationAction:(WKNavigationAction *)navigationAction
        windowFeatures:(WKWindowFeatures *)windowFeatures
{
  if (!navigationAction.targetFrame.isMainFrame)
    [webView loadRequest:navigationAction.request];
  return nil;
}

@end

/* webkit command */

bool
nsxwidget_is_web_view (struct xwidget *xw)
{
  return xw->xwWidget != NULL &&
    [xw->xwWidget isKindOfClass:WKWebView.class];
}

/* @Note ATS - application transport security in `Info.plist` or
   remote pages will not loaded */
void
nsxwidget_webkit_goto_uri (struct xwidget *xw, const char *uri)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  NSString *urlString = [NSString stringWithUTF8String:uri];
  NSURL *url = [NSURL URLWithString:urlString];
  NSURLRequest *urlRequest = [NSURLRequest requestWithURL:url];
  [xwWebView loadRequest:urlRequest];
}

void
nsxwidget_webkit_zoom (struct xwidget *xw, double zoom_change)
{
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;
  xwWebView.magnification += zoom_change;
  // TODO: setMagnification:centeredAtPoint
}

/* Build lisp string */
static Lisp_Object
build_string_with_nsstr (NSString *nsstr)
{
  NSUInteger bytes = [nsstr maximumLengthOfBytesUsingEncoding:NSUTF8StringEncoding];
  char *buf = malloc (bytes); /* XXX: How is this free'd, GC? */
  [nsstr getCString:buf maxLength:bytes encoding:NSUTF8StringEncoding];
  return build_string (buf);
}

/* Recursively convert an objc native type JavaScript value to a Lisp
   value.  Mostly copied from GTK xwidget `webkit_js_to_lisp' */
static Lisp_Object
js_to_lisp (id value)
{
  if (value == nil || [value isKindOfClass:NSNull.class])
    return Qnil;
  else if ([value isKindOfClass:NSString.class])
    return build_string_with_nsstr ((NSString *) value);
  else if ([value isKindOfClass:NSNumber.class])
    {
      NSNumber *nsnum = (NSNumber *) value;
      char type = nsnum.objCType[0];
      if (type == 'B')
        return nsnum.boolValue? Qt : Qnil;
      else
        {
          if (type == 'i' || type == 'l')
            return make_number (nsnum.longValue);
          else if (type == 'f' || type == 'd')
            return make_float (nsnum.doubleValue);
          // else fall through
        }
    }
  else if ([value isKindOfClass:NSArray.class])
    {
      NSArray *nsarr = (NSArray *) value;
      EMACS_INT n = nsarr.count;
      Lisp_Object obj;
      struct Lisp_Vector *p = allocate_vector (n);

      for (ptrdiff_t i = 0; i < n; ++i)
        p->contents[i] = js_to_lisp ([nsarr objectAtIndex:i]);
      XSETVECTOR (obj, p);
      return obj;
    }
  else if ([value isKindOfClass:NSDictionary.class])
    {
      NSDictionary *nsdict = (NSDictionary *) value;
      NSArray *keys = nsdict.allKeys;
      ptrdiff_t n = keys.count;
      Lisp_Object obj;
      /* TODO: can we use a regular list here?  */
      struct Lisp_Vector *p = allocate_vector (n);

      for (ptrdiff_t i = 0; i < n; ++i)
        {
          NSString *prop_key = (NSString *) [keys objectAtIndex:i];
          id prop_value = [nsdict valueForKey:prop_key];
          p->contents[i] = Fcons (build_string_with_nsstr (prop_key),
                                  js_to_lisp (prop_value));
        }
      XSETVECTOR (obj, p);
      return obj;
    }
  NSLog (@"Unhandled number type in javascript result");
  return Qnil;
}

void
nsxwidget_webkit_execute_script (struct xwidget *xw, const char *script,
                                 Lisp_Object fun)
{
  NSString *javascriptString = [NSString stringWithUTF8String:script];
  XwWebView *xwWebView = (XwWebView *) xw->xwWidget;

  /* FIXME: With objc blocks, no need to convert lisp FUN to
     `gpointer', thus, no USE_LSB_TAG.  But still possible disaster if
     FUN is garbage collected.  Is there any method to prohibit it
     from garbage collected? */

  [xwWebView evaluateJavaScript:javascriptString
              completionHandler:^(id result, NSError *error) {
      if (error)
        NSLog (@"evaluateJavaScript error : %@", error.localizedDescription);
      else if (result)
        {
          /* I assumed `result' actual instance type is objc types
             corresponding javascript types translated by webview or
             javascript core. */
          // NSLog (@"result=%@, type=%@", result, [result class]);
          Lisp_Object lisp_value = js_to_lisp (result);
          store_xwidget_js_callback_event (xw, fun, lisp_value);
        }
    }];
}

/* window contains xwidget */

@implementation XwWindow
- (BOOL)isFlipped { return YES; }
@end

/* xw : xwidget model, ns cocoa part */

void
nsxwidget_init(struct xwidget *xw)
{
  block_input ();
  NSRect rect = NSMakeRect (0, 0, xw->width, xw->height);
  xw->xwWidget = [[XwWebView alloc]
                   initWithFrame:rect
                   configuration:[[WKWebViewConfiguration alloc] init]
                         xwidget:xw];
  xw->xwWindow = [[XwWindow alloc]
                   initWithFrame:rect];
  [xw->xwWindow addSubview:xw->xwWidget];
  xw->xv = NULL; /* for 1 to 1 relationship of webkit2 */
  unblock_input ();
}

void
nsxwidget_kill (struct xwidget *xw)
{
  if (xw)
    {
      xw->xv->model = Qnil; // Make sure related view stale
      [xw->xwWidget removeFromSuperviewWithoutNeedingDisplay];
      [xw->xwWidget release];
      [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
      [xw->xwWindow release];
      xw->xwWidget = nil;
    }
}

void
nsxwidget_resize (struct xwidget *xw)
{
  if (xw->xwWidget)
    {
      [xw->xwWindow setFrameSize:NSMakeSize(xw->width, xw->height)];
      [xw->xwWidget setFrameSize:NSMakeSize(xw->width, xw->height)];
    }
}

Lisp_Object
nsxwidget_get_size (struct xwidget *xw)
{
  return list2 (make_number (xw->xwWidget.frame.size.width),
                make_number (xw->xwWidget.frame.size.height));
}

/* xv : xwidget view, ns cocoa part */

@implementation XvWindow : NSView
- (BOOL)isFlipped { return YES; }
@end

void
nsxwidget_init_view (struct xwidget_view *xv,
                     struct xwidget *xw,
                     struct glyph_string *s,
                     int x, int y)
{
  /* `nsxwidget_draw_glyph' below will calculate correct position and
     size of clip to draw in emacs buffer window. Thus, just begin at
     origin with no crop. */
  xv->x = x;
  xv->y = y;
  xv->clip_left = 0;
  xv->clip_right = xw->width;
  xv->clip_top = 0;
  xv->clip_bottom = xw->height;

  xv->xvWindow = [[XvWindow alloc]
                   initWithFrame:NSMakeRect (x, y, xw->width, xw->height)];
  xv->xvWindow.xw = xw;
  xv->xvWindow.xv = xv;

  xw->xv = xv; /* For 1 to 1 relationship of webkit2 */
  [xv->xvWindow addSubview:xw->xwWindow];

  xv->emacswindow = FRAME_NS_VIEW (s->f);
  [xv->emacswindow addSubview:xv->xvWindow];
}

void
nsxwidget_delete_view (struct xwidget_view *xv)
{
  if (!EQ (xv->model, Qnil))
    {
      struct xwidget *xw = XXWIDGET (xv->model);
      [xw->xwWindow removeFromSuperviewWithoutNeedingDisplay];
      xw->xv = NULL; /* Now model has no view */
    }
  [xv->xvWindow removeFromSuperviewWithoutNeedingDisplay];
  [xv->xvWindow release];
}

void
nsxwidget_show_view (struct xwidget_view *xv)
{
  xv->hidden = NO;
  [xv->xvWindow setFrameOrigin:NSMakePoint(xv->x + xv->clip_left,
                                           xv->y + xv->clip_top)];
}

void
nsxwidget_hide_view (struct xwidget_view *xv)
{
  xv->hidden = YES;
  [xv->xvWindow setFrameOrigin:NSMakePoint(10000, 10000)];
}

void
nsxwidget_resize_view (struct xwidget_view *xv, int width, int height)
{
  [xv->xvWindow setFrameSize:NSMakeSize(width, height)];
}

void
nsxwidget_move_view (struct xwidget_view *xv, int x, int y)
{
  [xv->xvWindow setFrameOrigin:NSMakePoint (x, y)];
}

/* Move model window in container (view window) */
void
nsxwidget_move_widget_in_view (struct xwidget_view *xv, int x, int y)
{
  struct xwidget *xww = xv->xvWindow.xw;
  [xww->xwWindow setFrameOrigin:NSMakePoint (x, y)];
}

void
nsxwidget_set_needsdisplay (struct xwidget_view *xv)
{
  xv->xvWindow.needsDisplay = YES;
}
