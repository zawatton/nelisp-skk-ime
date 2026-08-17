;; widgets.el --- GTK4 widget helpers, in NeLisp (AOT, object mode).
;;
;; First slice of main.c's GTK layer.  `grid_add_row' is here because it
;; is the only GTK helper in main.c that touches no application state:
;; every other one reaches into `App' or `SettingsWindow' through the
;; `gpointer user_data' a GTK callback receives, which needs struct
;; offsets, so those wait for the offset-assertion machinery.
;;
;; Its label text arrives as a `const char *' the C caller owns -- the
;; literals stay in main.c -- so, exactly as in registry.el, this module
;; never references a string and stays inside object-mode AOT's
;; `:object-mode-no-strings' rule.
;;
;; Requires `(:f32 LIT)' support in the AOT compiler (see build.el's
;; NELISP-TOO-OLD guard): `gtk_label_set_xalign' takes a C `float', and
;; passing a double there is an ABI mismatch that corrupts the value
;; silently rather than failing.
;;
;; GTK signatures relied on:
;;   GtkWidget *gtk_label_new(const char *str)
;;   void gtk_label_set_xalign(GtkLabel *self, float xalign)
;;   void gtk_widget_set_hexpand(GtkWidget *widget, gboolean expand)
;;   void gtk_grid_attach(GtkGrid *grid, GtkWidget *child,
;;                        int column, int row, int width, int height)
;;
;; The GTK_LABEL()/GTK_GRID() casts in the C original are compile-time
;; type checks with no runtime effect in a release build, so the pointer
;; is passed through unchanged here.

(seq
 ;; void grid_add_row(GtkGrid *grid, int row, const char *label_text,
 ;;                   GtkWidget *control)
 ;;
 ;; Appends a left-aligned label in column 0 and CONTROL in column 1,
 ;; with CONTROL taking the horizontal slack.  Used for every setting
 ;; except the standalone checkboxes, whose own label is the text.
 (defun grid_add_row (grid row label_text control)
   (let ((label (extern-call gtk_label_new label_text)))
     (extern-call gtk_label_set_xalign label (:f32 0.0))
     (extern-call gtk_widget_set_hexpand control 1)
     (extern-call gtk_grid_attach grid label 0 row 1 1)
     (extern-call gtk_grid_attach grid control 1 row 1 1)
     0)))
