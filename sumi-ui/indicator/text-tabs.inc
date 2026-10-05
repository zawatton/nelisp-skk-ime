static void on_text_open(GtkButton *button, gpointer user_data) {
  SettingsWindow *sw = user_data;
  int action = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(button), "text-action"));
  if (!text_settings_open((action & 1) != 0, (action & 2) != 0))
    gtk_label_set_text(GTK_LABEL(sw->status_label), "ファイルまたは編集画面を開けませんでした");
}
static void on_text_status(GtkButton *button, gpointer user_data) {
  (void)button;
  SettingsWindow *sw = user_data;
  char *status = text_settings_status();
  gtk_label_set_text(GTK_LABEL(sw->remap_status), status);
  g_free(status);
}
static GtkWidget *text_button(SettingsWindow *sw, const char *label, int action) {
  GtkWidget *b = gtk_button_new_with_label(label);
  g_object_set_data(G_OBJECT(b), "text-action", GINT_TO_POINTER(action));
  g_signal_connect(b, "clicked", G_CALLBACK(on_text_open), sw);
  return b;
}
static GtkWidget *build_tab_text(SettingsWindow *sw, gboolean rules) {
  GtkWidget *grid = gtk_grid_new();
  gtk_grid_set_row_spacing(GTK_GRID(grid), 6);
  gtk_grid_set_column_spacing(GTK_GRID(grid), 12);
  gtk_widget_set_margin_top(grid, 12); gtk_widget_set_margin_bottom(grid, 12);
  gtk_widget_set_margin_start(grid, 12); gtk_widget_set_margin_end(grid, 12);
  int row = 0;
  if (rules) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    sw->radio_half = gtk_check_button_new_with_label("半角");
    GtkWidget *full = gtk_check_button_new_with_label("全角");
    gtk_check_button_set_group(GTK_CHECK_BUTTON(full), GTK_CHECK_BUTTON(sw->radio_half));
    gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->text_baseline.width ? full : sw->radio_half), TRUE);
    gtk_box_append(GTK_BOX(box), sw->radio_half); gtk_box_append(GTK_BOX(box), full);
    grid_add_row(GTK_GRID(grid), row++, "記号の幅", box);
    sw->check_pair = gtk_check_button_new_with_label("括弧を自動で閉じる");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_pair), sw->text_baseline.auto_pair);
    gtk_grid_attach(GTK_GRID(grid), sw->check_pair, 0, row++, 2, 1);
  } else {
    sw->check_remap = gtk_check_button_new_with_label("キー置き換えを有効にする");
    gtk_check_button_set_active(GTK_CHECK_BUTTON(sw->check_remap), sw->text_baseline.enabled);
    gtk_grid_attach(GTK_GRID(grid), sw->check_remap, 0, row++, 2, 1);
    const char *choices[] = {"OSのまま", "US", "JIS", NULL};
    sw->drop_layout = gtk_drop_down_new_from_strings(choices);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(sw->drop_layout), sw->text_baseline.layout);
    grid_add_row(GTK_GRID(grid), row++, "配列", sw->drop_layout);
  }
  gtk_grid_attach(GTK_GRID(grid), text_button(sw, rules ? "記号と括弧の表を編集..." : "キー置き換え・キーの確認を開く...", rules ? 3 : 2), 0, row++, 2, 1);
  gtk_grid_attach(GTK_GRID(grid), text_button(sw, "テキストファイルを開く", rules ? 1 : 0), 0, row++, 2, 1);
  GtkWidget *note = gtk_label_new("適用すると常駐プログラムが自動で読み直します");
  gtk_label_set_wrap(GTK_LABEL(note), TRUE);
  gtk_grid_attach(GTK_GRID(grid), note, 0, row++, 2, 1);
  if (!rules) {
    sw->remap_status = gtk_label_new("");
    gtk_label_set_xalign(GTK_LABEL(sw->remap_status), 0);
    gtk_label_set_wrap(GTK_LABEL(sw->remap_status), TRUE);
    gtk_label_set_selectable(GTK_LABEL(sw->remap_status), TRUE);
    GtkWidget *scroll = gtk_scrolled_window_new();
    gtk_widget_set_vexpand(scroll, TRUE);
    gtk_scrolled_window_set_min_content_height(GTK_SCROLLED_WINDOW(scroll), 80);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(scroll), sw->remap_status);
    gtk_grid_attach(GTK_GRID(grid), scroll, 0, row++, 2, 1);
    GtkWidget *refresh = gtk_button_new_with_label("状態を更新");
    g_signal_connect(refresh, "clicked", G_CALLBACK(on_text_status), sw);
    gtk_grid_attach(GTK_GRID(grid), refresh, 0, row++, 2, 1);
    on_text_status(NULL, sw);
  }
  return grid;
}
