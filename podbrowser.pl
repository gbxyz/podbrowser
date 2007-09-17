#!/usr/bin/perl
# $Id: podbrowser.pl,v 1.43 2006/08/08 10:52:40 gavin Exp $
# Copyright (c) 2004 Gavin Brown. All rights reserved. This program is free
# software; you can redistribute it and/or modify it under the same terms
# as Perl itself.
use File::Basename qw(dirname);
use File::Temp qw(tempdir tempfile);
use Gtk2 -init;
use Gtk2::GladeXML 1.001;
use Gtk2::Pango;
use Gtk2::Ex::Simple::List;
use Gtk2::Ex::PodViewer 0.16;
use Gtk2::Ex::PodViewer::Parser qw(decode_entities);
use Locale::gettext;
use Pod::Simple::Search;
use POSIX qw(setlocale);
use Storable;
use URI::Escape;
use HTML::Entities qw(encode_entities_numeric);
use strict;

### set up global variables:
my $NAME		= 'PodBrowser';
my $VERSION		= '0.11';
my $PREFIX		= '@PREFIX@';
my $GLADE_FILE		= (-d $PREFIX ? sprintf('%s/share/%s', $PREFIX, lc($NAME)) : $ENV{PWD}).sprintf('/%s.glade', lc($NAME));
my $LOCALE_DIR		= (-d $PREFIX ? "PREFIX/share/locale" : $ENV{PWD}.'/locale');
my $RCFILE		= sprintf('%s/.%src', $ENV{HOME}, lc($NAME));
my $DOC_CACHE		= sprintf('%s/.%s_cache', $ENV{HOME}, lc($NAME));

### instance specific ones:
my $SEARCH_OFFSET	= 0;
my $MAXIMIZED		= 0;
my $FULLSCREEN		= 0;
my $OPTIONS		= load_config();
my @HISTORY		= split(/\|/, $OPTIONS->{history});
my @BOOKMARKS		= split(/\|/, $OPTIONS->{bookmarks});
my $BOOKMARK_ITEMS	= {};
my $PATHS		= {};
my $NO_REDRAW		= 0;
my $MTIME		= 0;
my @FORWARD;
my @BACK;
my $CURRENT_DOCUMENT;
my $LAST_SEARCH_STR;
my $LAST_FAILED_STR;

### set up l10n support:
setlocale(LC_ALL, $ENV{LANG});
bindtextdomain(lc($NAME), $LOCALE_DIR);
textdomain(lc($NAME));
{
    no warnings qw(redefine);
    my $LH = Locale::gettext->domain(lc($NAME));
    sub gettext { $LH->get(@_) }
}

### bits we'll be reusing:
chomp(my $OPENER	= `which gnome-open 2> /dev/null`);
my $APP			= Gtk2::GladeXML->new($GLADE_FILE);
my $THEME		= get_an_icon_theme();
my $TIPS		= Gtk2::Tooltips->new;
my $IDX_PBF		= Gtk2::Gdk::Pixbuf->new_from_file($THEME->lookup_icon('stock_bookmark', 16, 'force-svg')->get_filename)->scale_simple(16, 16, 'bilinear');
my $PAGE_PBF		= Gtk2::Gdk::Pixbuf->new_from_file($THEME->lookup_icon('stock_new-text', 16, 'force-svg')->get_filename)->scale_simple(16, 16, 'bilinear');
my $FOLDER_PBF		= Gtk2::Gdk::Pixbuf->new_from_file($THEME->lookup_icon('gnome-fs-directory', 16, 'force-svg')->get_filename)->scale_simple(16, 16, 'bilinear');
my $NORMAL_CURSOR	= Gtk2::Gdk::Cursor->new('left_ptr');
my $BUSY_CURSOR		= Gtk2::Gdk::Cursor->new('watch');
my $ITEMS		= {};
my %categories		= (
	funcs		=> gettext('Functions'),
	modules		=> gettext('Modules'),
	pragma		=> gettext('Pragmas'),
	pods		=> gettext('POD Documents'),
);
my $CATEGORY_PBFS	= {};

my %TOOLBAR_STYLES = (
	gettext('Icons')		=> 'icons',
	gettext('Text')			=> 'text',
	gettext('Both')			=> 'both',
	gettext('Both Horizontal')	=> 'both-horiz',
);

$OPTIONS->{variable_font}	= (defined($OPTIONS->{variable_font})	? $OPTIONS->{variable_font}	: 'Sans 10');
$OPTIONS->{fixed_font}		= (defined($OPTIONS->{fixed_font})	? $OPTIONS->{fixed_font}	: 'Monospace 10');
$OPTIONS->{header_color}	= (defined($OPTIONS->{header_color})	? $OPTIONS->{header_color}	: '#404080');
$OPTIONS->{preformat_color}	= (defined($OPTIONS->{preformat_color})	? $OPTIONS->{preformat_color}	: '#606060');
$OPTIONS->{toolbar_style}	= (defined($OPTIONS->{toolbar_style})	? $OPTIONS->{toolbar_style}	: 'icons');

### start building the UI:

$APP->signal_autoconnect_from_package(__PACKAGE__);
$APP->get_widget('location')->disable_activate;
$APP->get_widget('open_dialog_location')->disable_activate;

# this seems not to be applied from the glade, so force it:
$APP->get_widget('location_toolitem')->set_expand(1);

my $group = Gtk2::AccelGroup->new;
$group->connect(ord(1),   ['mod1-mask'],    ['visible'], sub { $APP->get_widget('notebook')->set_current_page(0) });
$group->connect(ord(2),   ['mod1-mask'],    ['visible'], sub { $APP->get_widget('notebook')->set_current_page(1) });
$group->connect(ord('L'), ['control-mask'], ['visible'], sub { $APP->get_widget('location')->entry->grab_focus });

$APP->get_widget('main_window')->add_accel_group($group);

my $toolbar_style_combo = Gtk2::ComboBox->new_text;
for (my $i = 0 ; $i < scalar(keys(%TOOLBAR_STYLES)) ; $i++) {
	my $style = (sort(keys(%TOOLBAR_STYLES)))[$i];
	$toolbar_style_combo->append_text($style);
	$toolbar_style_combo->set_active($i) if ($TOOLBAR_STYLES{$style} eq $OPTIONS->{toolbar_style});
}
$APP->get_widget('prefs_table')->attach_defaults($toolbar_style_combo, 1, 2, 4, 5);
$toolbar_style_combo->show;

my $viewer = Gtk2::Ex::PodViewer->new;

$viewer->set_cursor_visible(undef);
$viewer->signal_connect('link_clicked' => \&link_clicked);
$APP->get_widget('viewer_scrwin')->add($viewer);

$viewer->signal_connect('link_enter', sub { set_status($_[1]) });
$viewer->signal_connect('link_leave', sub { set_status('') });

setup_display();

$viewer->show;

-r $DOC_CACHE ? $viewer->set_db(retrieve($DOC_CACHE)) :  $viewer->_init_db;

### build a SimpleList from the glade widget for the document index:
my $page_index	= Gtk2::Ex::Simple::List->new_from_treeview(
	$APP->get_widget('document_index'),
	icon	=> 'pixbuf',
	mark	=> 'text',
	link	=> 'hidden',
);

$page_index->get_selection->signal_connect('changed', sub {
	my $idx = ($page_index->get_selected_indices)[0];
	my $mark = $page_index->{data}[$idx][2];
	$viewer->jump_to($mark);
	return 1;
});

### build a tree widget for the full index:
my $model = Gtk2::TreeStore->new(qw/Gtk2::Gdk::Pixbuf Glib::String/);
my $treeview = $APP->get_widget('index');
$treeview->set_model($model);
my $treecolumn = Gtk2::TreeViewColumn->new;
$treecolumn->set_title('Name');
my $treecell = Gtk2::CellRendererPixbuf->new;
$treecolumn->pack_start($treecell, 0);
$treecolumn->add_attribute($treecell, pixbuf => 0);
$treecell = Gtk2::CellRendererText->new;
$treecell->set('ellipsize-set' => 0, 'ellipsize' => 'end');
$treecolumn->pack_start($treecell, 1);
$treecolumn->add_attribute($treecell, text => 1);
$treeview->append_column($treecolumn);

$treeview->get_selection->signal_connect('changed', \&index_changed);

eval {
	my $icon = Gtk2::Gdk::Pixbuf->new_from_file($THEME->lookup_icon(lc($NAME), 16, 'force-svg')->get_filename);
	$APP->get_widget('main_window')->set_icon($icon);
	$APP->get_widget('view_source_window')->set_icon($icon);
	$APP->get_widget('bookmarks_dialog')->set_icon($icon);
	$APP->get_widget('display_preferences_dialog')->set_icon($icon);
};
print STDERR $@;

Glib::Timeout->add(1000, \&watch_file);

### apply the user's previous preferences:
$APP->get_widget('notebook')->set_current_page(int($OPTIONS->{active_page}));
$APP->get_widget('pane')->set_position($OPTIONS->{pane_position} || 200);
$APP->get_widget('show_index')->set_active($OPTIONS->{show_index} == 0 && defined($OPTIONS->{show_index}) ? undef : 1);
$APP->get_widget('location')->set_popdown_strings('', @HISTORY);
$APP->get_widget('main_window')->maximize if ($OPTIONS->{maximized} == 1);
$APP->get_widget('main_window')->set_default_size(
	($OPTIONS->{window_x} > 0 ? $OPTIONS->{window_x} : 800),
	($OPTIONS->{window_y} > 0 ? $OPTIONS->{window_y} : 600),
);

$OPTIONS->{watch} = (!defined($OPTIONS->{watch}) ? 1 : ($OPTIONS->{watch} == 0 ? 0 : 1));
$APP->get_widget('toggle_watch')->set_active($OPTIONS->{watch} == 0 ? undef : 1);

$APP->get_widget('main_window')->signal_connect('window-state-event', \&window_changed_state);

### load the bookmarks:
foreach my $bookmark (@BOOKMARKS) {
	add_bookmark_item($bookmark);
}

### construct the bookmarks list:
my $bookmarks_list = Gtk2::Ex::Simple::List->new_from_treeview(
	$APP->get_widget('bookmarks_list'),
	icon	=> 'pixbuf',
	doc	=> 'text',
);

$APP->get_widget('main_window')->show;

my $completion_store = Gtk2::ListStore->new('Glib::String');

load_index();

my $completion = Gtk2::EntryCompletion->new;
$completion->set_model($completion_store);
$completion->set_text_column(0);
$completion->set_inline_completion(1);
$completion->signal_connect('match-selected', sub {
	my ($completion, $model, $iter) = @_;
	my $value = $model->get_value($iter, 0);
	set_location($value);
});

my $completion2 = Gtk2::EntryCompletion->new;
$completion2->set_model($completion_store);
$completion2->set_text_column(0);
$completion2->set_inline_completion(1);

$APP->get_widget('location')->entry->set_completion($completion);
$APP->get_widget('open_dialog_location')->entry->set_completion($completion2);

$APP->get_widget('view_source_text')->set_border_window_size('top', 6);
$APP->get_widget('view_source_text')->set_border_window_size('bottom', 6);
$APP->get_widget('view_source_text')->set_border_window_size('left', 6);
$APP->get_widget('view_source_text')->set_border_window_size('right', 6);
$APP->get_widget('view_source_text')->modify_bg('normal', Gtk2::Gdk::Color->new(65535, 65535, 65535));

$APP->get_widget('back_button')->set_menu(Gtk2::Menu->new);
$APP->get_widget('forward_button')->set_menu(Gtk2::Menu->new);
$APP->get_widget('up_button')->set_menu(Gtk2::Menu->new);

### if the program was run with an argument, load the argument as a document:
set_location($ARGV[0]) if (defined $ARGV[0] && $ARGV[0] ne '');

Gtk2->main;

exit;

sub location_entry_changed {
	$APP->get_widget('go_button')->set_sensitive($APP->get_widget('location')->entry->get_text ne '');
	return 1;
}
sub search_entry_changed {
	$APP->get_widget('search_button')->set_sensitive($APP->get_widget('search_entry')->get_text ne '');
	return 1;
}

sub watch_file {
	return 1 if ($OPTIONS->{watch} != 1);
	my $file = $APP->get_widget('location')->entry->get_text;
	go() if ( defined $file && (stat($file))[9] > $MTIME);
	return 1;
}

### pops up the 'open document' dialog:
sub open_dialog {
	$APP->get_widget('open_dialog')->set_icon($APP->get_widget('main_window')->get_icon);
	$APP->get_widget('open_dialog')->show_all;
	$APP->get_widget('open_dialog_location')->set_popdown_strings($APP->get_widget('location')->entry->get_text, @HISTORY);
	return 1;
}

### handles the 'open document' dialog response:
sub open_dialog_response {
	if ($_[1] eq 'ok' || $_[1] == 1) {
		set_location($APP->get_widget('open_dialog_location')->entry->get_text);
	}
	$APP->get_widget('open_dialog')->hide_all;
	return 1;
}
sub open_dialog_delete_event {
	$APP->get_widget('open_dialog')->hide_all;
	return 1;
}
sub on_open_dialog_location_activate {
	$APP->get_widget('open_dialog')->signal_emit('response', 1);
	return 1;
}
sub browse_button_clicked {
	my $dialog = Gtk2::FileChooserDialog->new(
		gettext('Choose File'),
		undef,
		'open',
		'gtk-cancel'	=> 'cancel',
		'gtk-ok'	=> 'ok'
	);
	$dialog->signal_connect('response', sub {
		if ($_[1] eq 'ok') {
			$APP->get_widget('open_dialog_location')->entry->set_text($dialog->get_filename);
		}
		$dialog->destroy;
	});
	$dialog->set_icon($APP->get_widget('main_window')->get_icon);
	$dialog->run;
	return 1;
}

### shows/hides the left pane of the window:
sub toggle_index {
	if ($_[0]->get_active) {
		$APP->get_widget('notebook')->show_all;
	} else {
		$APP->get_widget('notebook')->hide_all;
	}
	$OPTIONS->{show_index} = ($_[0]->get_active ? 1 : 0);

	return 1;
}

sub toggle_watch {
	$OPTIONS->{watch} = $APP->get_widget('toggle_watch')->get_active ? 1 : 0;
}

sub about {
	Gtk2::AboutDialog->set_url_hook(\&open_url);
	my $dialog = Gtk2::AboutDialog->new;
	$dialog->set('name'		=> $NAME);
	$dialog->set('version'		=> $VERSION);
	$dialog->set('comments'		=> gettext('A Perl Documentation Browser for GNOME'));
	$dialog->set('copyright'	=> gettext('Copyright 2005 Gavin Brown.'));
	$dialog->set('website'		=> sprintf('http://jodrell.net/projects/%s', lc($NAME)));
	$dialog->set('icon'		=> $APP->get_widget('main_window')->get_icon);
	$dialog->set('logo'		=> $APP->get_widget('main_window')->get_icon);
	$dialog->signal_connect('delete_event', sub { $dialog->destroy });
	$dialog->signal_connect('response', sub { $dialog->destroy });
	$dialog->signal_connect('close', sub { $dialog->destroy });
	$dialog->show_all;
	return 1;
}

sub set_ui_busy {
    return unless $APP->get_widget('main_window')->window;
	$APP->get_widget('main_window')->window->set_cursor($BUSY_CURSOR);
	$viewer->get_window('text')->set_cursor($BUSY_CURSOR);
	Gtk2->main_iteration while (Gtk2->events_pending);
}

sub set_ui_waiting {
    return unless $APP->get_widget('main_window')->window;
	$APP->get_widget('main_window')->window->set_cursor($NORMAL_CURSOR);
	$viewer->get_window('text')->set_cursor($NORMAL_CURSOR);
	Gtk2->main_iteration while (Gtk2->events_pending);
}

### this is used when the user requests a new document, via the location entry,
### the go button, the 'open document' dialog, the index or via a clicked link:
sub go {
	my $no_reselect = shift;
	my $text = $APP->get_widget('location')->entry->get_text;

	set_ui_busy();

	if (!$viewer->load($text)) {
		my @children = grep { /^$text\:\:/ } keys(%{$viewer->get_db});
		if (scalar(@children) > 0) {
			$viewer->load_string(generate_pod_index($text, @children));
			set_ui_waiting();

		} else {
			$APP->get_widget('location')->entry->set_text($CURRENT_DOCUMENT);
			pop(@BACK);
			set_ui_waiting();
			show_fail_dialog($text);

		}

	} else {
		$MTIME = time();
		$CURRENT_DOCUMENT = $text;
		$APP->get_widget('main_window')->set_title(sprintf(gettext('%s - Pod Browser'), $text));
		set_ui_waiting();

		### populate the index:
		@{$page_index->{data}} = ();
		map { push(@{$page_index->{data}}, [ $IDX_PBF, section_reformat(decode_entities($_)), $_ ]) } $viewer->get_marks;
		unshift(@HISTORY, $text);

		### update the history, removing duplicates:
		my %seen;
		for (my $i = 0 ; $i < scalar(@HISTORY) ; $i++) {
			if (exists $seen{$HISTORY[$i]} && $seen{$HISTORY[$i]} == 1) {
				splice(@HISTORY, $i, 1);
			} else {
				$seen{$HISTORY[$i]} = 1;
			}
		}
		$APP->get_widget('location')->set_popdown_strings(@HISTORY);
		$LAST_SEARCH_STR = '';

		if (defined($PATHS->{$text}) && $no_reselect != 1) {
			$APP->get_widget('index')->expand_row($PATHS->{$text}, 1);
			$APP->get_widget('index')->scroll_to_cell($PATHS->{$text}, $APP->get_widget('index')->get_column(0), 1, 0.5, 0);
			$NO_REDRAW = 1;
			$APP->get_widget('index')->get_selection->select_path($PATHS->{$text});
			$NO_REDRAW = 0;
		}

		### the back button:
		if (scalar(@BACK) > 0) {
			$APP->get_widget('back_button')->set_sensitive(1);
			$APP->get_widget('back_button')->set_tooltip($TIPS, sprintf(gettext("Go back to '%s'"), $BACK[-1]), 1);

		} elsif (scalar(@BACK) < 1 && $APP->get_widget('back_button')->get('sensitive')) {
			$APP->get_widget('back_button')->set_sensitive(undef);

		}

		### the forward button:
		if (scalar(@FORWARD) > 0) {
			$APP->get_widget('forward_button')->set_sensitive(1);
			$APP->get_widget('forward_button')->set_tooltip($TIPS, sprintf(gettext("Go forward to '%s'"), $FORWARD[0]), 1);

		} elsif (scalar(@FORWARD) < 1) {
			$APP->get_widget('forward_button')->set_sensitive(undef);

		}

		### the up button:
		if ($APP->get_widget('location')->entry->get_text =~ /::/) {
			$APP->get_widget('up_button')->set_sensitive(1);
			my @parts = split(/::/, $APP->get_widget('location')->entry->get_text);
			pop(@parts);
			my $doc = join('::', @parts);
			$APP->get_widget('up_button')->set_tooltip($TIPS, sprintf(gettext("Go up to '%s'"), $doc), 1);

		} else {
			$APP->get_widget('up_button')->set_sensitive(undef);

		}

		### the "add bookmark" item. turn off if location is blank or is already bookmarked:
		$APP->get_widget('add_bookmark_item')->set_sensitive($APP->get_widget('location')->entry->get_text ne '' && !defined($BOOKMARK_ITEMS->{$APP->get_widget('location')->entry->get_text}));

		return 1;

	}

	return 1;
}

sub show_fail_dialog {
	my $text = shift;
	$LAST_FAILED_STR = $text;
	$APP->get_widget('load_failed_dialog_title_label')->set_markup(sprintf('<span size="large" weight="bold">%s</span>',  encode_entities_numeric(sprintf(gettext("Couldn't find a POD document for '%s'."), $text))));
	$APP->get_widget('load_failed_dialog')->show_all;
}

sub close_load_failed_dialog {
	$APP->get_widget('load_failed_dialog')->hide;
	return 1;
}

sub load_failed_dialog_response {
	close_load_failed_dialog();

	if ($_[1] == 49) {
		open_url(sprintf('http://search.cpan.org/search?query=%s', uri_escape($LAST_FAILED_STR)));

	} elsif ($_[1] == 99) {
		reload_index();
		set_location($LAST_FAILED_STR);

	}

	return 1;
}

sub close_window { close_program() }

sub close_program {
	if ($MAXIMIZED == 1) {
		$OPTIONS->{maximized} = 1;
	} else {
		$OPTIONS->{maximized} = 0;
		($OPTIONS->{window_x}, $OPTIONS->{window_y}) = $APP->get_widget('main_window')->get_size if ($FULLSCREEN == 0);
	}

	$OPTIONS->{active_page} = $APP->get_widget('notebook')->get_current_page;
	$OPTIONS->{pane_position} = $APP->get_widget('pane')->get_position;
	$OPTIONS->{history} = join('|', splice(@HISTORY, 0, 20));
	$OPTIONS->{bookmarks} = join('|', @BOOKMARKS);
	save_config();
	save_cache();
	exit 0;
}

sub load_config {
	my $OPTIONS = {};
	if (open(RCFILE, $RCFILE)) {
		while (<RCFILE>) {
			chomp;
			my ($name, $value) = split(/\s*=\s*/, $_, 2);
			$OPTIONS->{lc($name)} = $value;
		}
		close(RCFILE);
	}
	return $OPTIONS;
}

sub save_config {
	if (!open(RCFILE, ">$RCFILE")) {
		printf(STDERR "Cannot open file '%s' for writing: %s\n", $RCFILE, $!);
		return undef;
	} else {
		foreach my $key (sort(keys(%{$OPTIONS}))) {
			printf(RCFILE "%s=%s\n", $key, $OPTIONS->{$key});
		}
		close(RCFILE);
		return 1;
	}
	return undef;
}

sub save_cache {
	store($viewer->get_db, $DOC_CACHE);
}

sub link_clicked {
	my (undef, $text) = @_;
	$text =~ s/\"$//g;
	$text =~ s/^\"//g;

	return undef if ($text eq '');

	my @marks = $viewer->get_marks;
	my $seen = 0;
	map { s/^[\"\']//g ; s/[\"\']$//g ; $seen++ if (lc($_) eq lc($text)) } @marks;

	if ($seen > 0) {
		# link referred to an anchor:
		for (my $i = 0 ; $i < scalar(@marks) ; $i++) {
			$marks[$i] =~ s/^[\"\']//g;
			$marks[$i] =~ s/[\"\']$//g;
			if (lc($marks[$i]) eq lc($text)) {
				$page_index->select($i);
				return 1;
			}
		}

	} elsif ($text =~ /\|\/?/) {
		# link referred to an anchor, but with some named text:
		my ($text, $section) = split(/\|\/?/, $text, 2);
		link_clicked(undef, $section);

	} elsif ($text =~ /^(\w+)\:\/\//) {
		# link referred to a URL:
		open_url($text);

	} elsif ($text =~ /^\// && ! -e $text) {
		# link referred to a non-existent file, remove the leading slash and try again:
		$text =~ s/^\///;
		link_clicked(undef, $text);

	} elsif ($text =~ /\// && ! -e $text) {
		# link referred to a poddoc/anchor anchor, split the text and try with the second part:
		my ($doc, $section) = split(/\//, $text, 2);
		set_location($doc);
		link_clicked(undef, $section);

	} else {
		# link referred to another pod document:
		set_location($text);

	}
	return 1;

}

sub set_location {
	my $locn = shift;
	if ($APP->get_widget('location')->entry->get_text ne '') {
		push(@BACK, $APP->get_widget('location')->entry->get_text);
	}
	@FORWARD = ();
	$APP->get_widget('location')->entry->set_text($locn);
	go();
}

sub go_back {
	unshift(@FORWARD, $APP->get_widget('location')->entry->get_text);
	my $locn = pop(@BACK);
	$APP->get_widget('location')->entry->set_text($locn);
	go();
}

sub go_forward {
	push(@BACK, $APP->get_widget('location')->entry->get_text);
	my $locn = shift(@FORWARD);
	$APP->get_widget('location')->entry->set_text($locn);
	go();
}

sub go_up {
	my @parts = split(/::/, $APP->get_widget('location')->entry->get_text);
	pop(@parts);
	$APP->get_widget('location')->entry->set_text(join('::', @parts));
	push(@BACK, $CURRENT_DOCUMENT);
	@FORWARD = ();
	go();
}

sub show_back_button_menu {
	create_popup_menu($APP->get_widget('back_button')->get_menu, @BACK);
	return 1;
}

sub show_forward_button_menu {
	create_popup_menu($APP->get_widget('forward_button')->get_menu, @FORWARD);
	return 1;
}

sub show_up_button_menu {
	my @items = ();
	my @parts = ();
	my $doc = $APP->get_widget('location')->entry->get_text;
	foreach my $part (split(/::/, $doc)) {
		push(@parts, $part);
		my $this_doc = join('::', @parts);
		push(@items, $this_doc) unless ($this_doc eq $doc);
	}
	create_popup_menu($APP->get_widget('up_button')->get_menu, @items);
	return 1;
}

sub user_set_location {
	return undef if ($APP->get_widget('location')->entry->get_text eq '');
	push(@BACK, $CURRENT_DOCUMENT) if ($CURRENT_DOCUMENT ne '' && $CURRENT_DOCUMENT ne $APP->get_widget('location')->entry->get_text);
	@FORWARD = ();
	go();
}

sub search {
	my $str = $APP->get_widget('search_entry')->get_text;

	$str =~ s/^\s*$//g;

	return undef if ($str eq '');

	set_ui_busy();

	my $doc = $viewer->get_buffer->get_text(
		$viewer->get_buffer->get_start_iter,
		$viewer->get_buffer->get_end_iter,
		undef,
	);

	$APP->get_widget('search_entry')->set_sensitive(0);

	$SEARCH_OFFSET = 0 if ($str ne $LAST_SEARCH_STR);
	$LAST_SEARCH_STR = $str;

	my $chunk = substr($doc, $SEARCH_OFFSET);

	while ($chunk =~ /($str)/ig) {
		Gtk2->main_iteration while (Gtk2->events_pending);

		$SEARCH_OFFSET += pos($chunk);

		my $iter = $viewer->get_buffer->get_iter_at_offset($SEARCH_OFFSET);
		$viewer->scroll_to_iter($iter, undef, 1, 0, 0);

		$APP->get_widget('search_entry')->set_sensitive(1);
		$APP->get_widget('search_entry')->grab_focus();

		$viewer->get_buffer->move_mark(
			$viewer->get_buffer->get_mark('insert'), 
			$viewer->get_buffer->get_iter_at_offset($SEARCH_OFFSET - length($1)),
		);
		$viewer->get_buffer->move_mark(
			$viewer->get_buffer->get_mark('selection_bound'), 
			$viewer->get_buffer->get_iter_at_offset($SEARCH_OFFSET),
		);

		set_ui_waiting();

		return 1;
	}

	$APP->get_widget('search_entry')->set_sensitive(1);
	$APP->get_widget('search_entry')->grab_focus();

	$SEARCH_OFFSET = 0;
	set_ui_waiting();

	my $dialog = Gtk2::MessageDialog->new($APP->get_widget('main_window'), 'modal', 'info', 'ok', sprintf(gettext("The string '%s' was not found."), $str));
	$dialog->signal_connect('response', sub { $dialog->destroy });
	$dialog->show_all;

	return undef;
}

sub select_all {
	$viewer->get_buffer->move_mark(
		$viewer->get_buffer->get_mark('insert'), 
		$viewer->get_buffer->get_start_iter,
	);
	$viewer->get_buffer->move_mark(
		$viewer->get_buffer->get_mark('selection_bound'), 
		$viewer->get_buffer->get_end_iter,
	);
	return 1;
}

sub search_dialog {
	$APP->get_widget('search_dialog_entry')->set_text($APP->get_widget('search_entry')->get_text);
	$APP->get_widget('search_dialog')->show_all;
	return 1;
}

sub search_dialog_close {
	$APP->get_widget('search_dialog')->hide_all;
	return 1;
}

sub search_dialog_entry_activate() {
	search_dialog_response(undef, 'ok');
	return 1;
}

sub search_dialog_response {
	if ($_[1] eq 'ok') {
		$APP->get_widget('search_entry')->set_text($APP->get_widget('search_dialog_entry')->get_text);
		search();

	}

	$APP->get_widget('search_dialog')->hide_all;
	return 1;
}

sub open_url {
	my $url = (ref($_[0]) eq 'Gtk2::AboutDialog' ? $_[1] : $_[0]);

	if (!-x $OPENER) {
		my $dialog = Gtk2::MessageDialog->new($APP->get_widget('main_window'), 'modal', 'info', 'ok', gettext('Error opening URL'));
		$dialog->format_secondary_text("The 'gnome-open' program could not be found.");
		$dialog->signal_connect('response', sub { $dialog->destroy });
		$dialog->show_all;
		return undef;

	} else {
		system("$OPENER \"$url\" &");
		return 1;

	}
}

### this looks through the system for perl pod documents that reference functions, modules and pod
### documents, and creates a hash of hashes that can be used to build a sitewide index:
sub generate_index {
	my %PATHS;
	my $ITEMS = {};
	my $category;

	my @docs = sort(keys(%{$viewer->get_db}));

	foreach my $doc (@docs) {
		if ($doc =~ /^perl/) {
			$category = 'pods';

		} elsif ($doc =~ /^[a-z0-9]+$/) {
			$category = 'pragma';

		} elsif ($doc =~ /^[A-Z0-9]/ || $doc =~ /::/) {
			$category = 'modules';

		}
		$ITEMS->{$category}->{$doc}++;
	}

	# doing a reverse sort means that later versions of Perl are preferred over newer versions:
	foreach my $dir (reverse sort @INC) {
		if (-r "$dir/pod/perlfunc.pod"
                && (!exists $PATHS{perlfunc} || $PATHS{perlfunc} eq '') ) {
			$PATHS{perlfunc} = "$dir/pod/perlfunc.pod";
			last;
		}
	}

	$category = '';
	if (-r $PATHS{perlfunc}) {
		if (!open(PERLFUNC, $PATHS{perlfunc})) {
			print STDERR "$PATHS{perlfunc}: $!\n";

		} else {
			while (<PERLFUNC>) {
				if (/Alphabetical Listing of Perl Functions/) {
					$category = 'funcs';
				} elsif (/^=item/) {
					my (undef, $doc, undef) = split(' ', $_, 3);
					$doc =~ s/[^A-Za-z0-9\_\/\-]+//g;
					$ITEMS->{$category}->{$doc}++;
				}
			}
			close(PERLFUNC);
		}
	}

	return $ITEMS;
}

sub load_index {
	set_ui_busy();
	$model->clear;
	$ITEMS = generate_index();
	### populate the tree:
	foreach my $category (sort keys %{$ITEMS}) {
		Gtk2->main_iteration while (Gtk2->events_pending);
		if ($category ne '') {
			my $parent_iter = $model->append(undef);
			$model->set($parent_iter, 0, (defined($CATEGORY_PBFS->{$category}) ? $CATEGORY_PBFS->{$category} : $FOLDER_PBF));
			$model->set($parent_iter, 1, $categories{$category});
            unless ( $category eq 'modules' ) {
			foreach my $doc (sort keys %{$ITEMS->{$category}}) {
				Gtk2->main_iteration while (Gtk2->events_pending);
				if ($doc ne '') {
					my $iter = $model->append($parent_iter);
					$PATHS->{$doc} = $model->get_path($iter);
					$model->set($iter, 0, $PAGE_PBF);
					$model->set($iter, 1, $doc);
				}
			}
		}
	}
	}
    if ( $OPTIONS->{hierarchy_module} ) {
        $APP->get_widget('mod_tree')->set_active(1);
    }
    else {
        toggle_mod_tree();
    }

	$completion_store->clear;
	my @items = sort(keys(%{$viewer->get_db}), keys(%{$ITEMS->{funcs}}));
	foreach my $doc (@items) {
		$completion_store->set($completion_store->append, 0, $doc);
	}

	set_ui_waiting();

	return undef;
}

sub toggle_mod_tree {
    my $active = $APP->get_widget('mod_tree')->get_active();
    my $treeview = $APP->get_widget('index');
    my $model = $treeview->get_model();
    $OPTIONS->{hierarchy_module} = $active;
    set_ui_busy();
    my $category = 'modules';
    my $modules = $categories{$category};
    my $iter = $model->get_iter_first();
    while ( $model->get_value($iter, 1) ne $modules
                and ($iter = $model->iter_next($iter)) ) {
        1;
    }
    my $newiter;
    if ( $iter ) {
        my $next = $model->iter_next($iter);
        my $parent = $model->iter_parent($iter);
        $model->remove($iter);
        if ( defined $next ) {
            $newiter = $model->insert_before($parent, $next);
        } else {
            $newiter = $model->append($parent);
        }
    } else {
        my $parent = $model->append(undef);
        $newiter = $model->append($parent);
    }
    $model->set($newiter, 0, (defined($CATEGORY_PBFS->{$category}) ? $CATEGORY_PBFS->{$category} : $FOLDER_PBF));
    $model->set($newiter, 1, $categories{$category});
    if ( $active ) {
        my $tree = build_mod_tree([sort keys %{$ITEMS->{$category}}]);
        my $add_child;
        $add_child = sub {
            my $t = shift;
            my $iter = shift;
            my $path = shift || [];
            foreach ( sort keys %$t ) {
                my $iter_child = $model->append($iter);
                my $doc = join("::", @$path, $_ );
                $PATHS->{$doc} = $model->get_path($iter_child);
                $model->set( $iter_child, 0, $PAGE_PBF);
                $model->set( $iter_child, 1, $doc );
                if ( %{$t->{$_}} ) {
                    $add_child->($t->{$_}, $iter_child, [@$path, $_]);
                }
            }
        };
        $add_child->($tree, $newiter);
    } else {
        foreach my $doc (sort keys %{$ITEMS->{$category}}) {
            Gtk2->main_iteration while (Gtk2->events_pending);
            if ($doc ne '') {
                my $iter = $model->append($newiter);
                $PATHS->{$doc} = $model->get_path($iter);
                $model->set($iter, 0, $PAGE_PBF);
                $model->set($iter, 1, $doc);
            }
        }
    }
    $treeview->expand_row( $model->get_path($newiter), 0 );
    set_ui_waiting();
    return undef;
}

sub build_mod_tree {
    my $mods  = shift;
    my %tree;
    my $add_children = sub  {
        my $root = \%tree;
        foreach ( @_ ) {
            if ( exists $root->{$_} ) {
                $root = $root->{$_};
            } else {
                my $child = {};
                $root->{$_} = $child;
                $root = $child;
            }
        }
    };
    foreach ( @$mods ) {
        next if $_ eq '';
        $add_children->(split /::/, $_);
    }
    return \%tree;
}

sub section_reformat {
	my $str = shift;
	my @words = split(/[\s\t]+/, $str);
	my @return = '';
	foreach my $word (@words) {
		if ($word =~ /^[A-Z]+$/) {
			$word = ucfirst(lc($word));
		}
		push(@return, $word);
	}
	return join(' ', @return);
}

### this tracks the window's state:
sub window_changed_state {
	my $mask = $_[1]->changed_mask;
	if ("$mask" eq '[ withdrawn ]') {
		$MAXIMIZED  = 0;
		$FULLSCREEN = 0;
	} elsif ("$mask" eq '[ maximized ]') {
		if ($MAXIMIZED == 1) {
			$MAXIMIZED  = 0;
		} else {
			$MAXIMIZED  = 1;
		}
		$FULLSCREEN = 0;
	} elsif ("$mask" eq '[ fullscreen ]') {
		$MAXIMIZED  = 0;
		if ($FULLSCREEN == 1) {
			$FULLSCREEN  = 0;
		} else {
			$FULLSCREEN  = 1;
		}
	}
	return 1;
}

### this is called when the user clicks on an item in the site index:
my $index_changed_timeout;
sub index_changed {

	return 1 if ($NO_REDRAW == 1);

	my ($path) = $APP->get_widget('index')->get_selection->get_selected_rows;

	if (defined($path)) {
		my $path = $path->to_string;
		my $iter = $APP->get_widget('index')->get_model->get_iter_from_string($path);
		my $value = $APP->get_widget('index')->get_model->get_value($iter, 1);
		my $seen = 0;
		foreach my $category (keys %categories) {
			$seen++ if ($categories{$category} eq $value);
		}
		if ($seen < 1) {
			# defer loading the page, in case the user is
			# arrowing around in the index.
			Glib::Source->remove($index_changed_timeout) if ($index_changed_timeout);
			$index_changed_timeout = Glib::Timeout->add(200, sub {
				$APP->get_widget('location')->entry->set_text($value);
				go(1);
				$index_changed_timeout = 0;
				0; # don't run again
			});
		}
	}
	return 1;
}

### returns an icon theme. When running in a GNOME session, the default is fine. if not,
### we have to load a custom one:
sub get_an_icon_theme {
	my $theme;
	if (exists $OPTIONS->{theme} && $OPTIONS->{theme} ne '') {
		# user specified a particular theme in their .podbrowserrc:
		$theme = Gtk2::IconTheme->new;
		$theme->set_custom_theme($OPTIONS->{theme});
	} else {
		# get the default theme:
		$theme = Gtk2::IconTheme->get_default;
	}
	my @paths = (
		'/usr/share/icons',
		'/opt/share/icons',
		'/usr/local/share/icons',
		sprintf('%s/.icons',			$ENV{HOME}),
		sprintf('%s/.local/share/icons',	$ENV{HOME}),
		sprintf('%s/share/icons',		(-d $PREFIX ? $PREFIX : $ENV{PWD})),
		sprintf('%s/icons',			(-d $PREFIX ? $PREFIX : $ENV{PWD})),
		(-d $PREFIX ? $PREFIX : $ENV{PWD}),
	);
	map { $theme->append_search_path($_) } @paths;
	if ($theme->has_icon('gnome-mime-text') == 0) {
		# the first theme failed, try the 'gnome' theme:
		$theme = Gtk2::IconTheme->new;
		$theme->set_custom_theme('gnome');
		map { $theme->append_search_path($_) } @paths;
		if ($theme->has_icon('gnome-mime-text') == 0) {
			print STDERR "*** sorry, I tried my best but I still can't find a usable icon theme!\n";
			exit 256;
		}
	}
	return $theme;
}

### pop up the bookmarks editor:
sub edit_bookmarks_dialog {
	@{$bookmarks_list->{data}} = ();
	foreach my $bookmark (@BOOKMARKS) {
		push(@{$bookmarks_list->{data}}, [$PAGE_PBF, $bookmark]);
	}
	$APP->get_widget('bookmarks_dialog')->set_position('center');
	$APP->get_widget('bookmarks_dialog')->show_all;
	return 1;
}

### user clicked the "jump to" button on the dialog:
sub load_bookmark {
	my ($idx) = $bookmarks_list->get_selected_indices;
	return undef if (!defined($idx));
	my $bookmark = $BOOKMARKS[$idx];
	$APP->get_widget('bookmarks_dialog')->hide;
	link_clicked(undef, $bookmark);
	return 1;
}

### user clicked the "remove" button on the dialog:
sub remove_bookmark {
	my ($idx) = $bookmarks_list->get_selected_indices;
	return undef if (!defined($idx));
	my $bookmark = $BOOKMARKS[$idx];
	$APP->get_widget('bookmarks_menu')->get_submenu->remove($BOOKMARK_ITEMS->{$bookmark});
	splice(@{$bookmarks_list->{data}}, $idx, 1);
	splice(@BOOKMARKS, $idx, 1);
	return 1;
}

### just hide the dialog and return a true value so the dialog isn't destroyed:
sub edit_bookmarks_dialog_delete_event {
	$APP->get_widget('bookmarks_dialog')->hide;
	return 1;
}

### hide the dialog:
sub edit_bookmarks_dialog_response {
	$APP->get_widget('bookmarks_dialog')->hide;
	return 1;
}

### user clicked the "add bookmark" menu item:
sub add_bookmark {
	my $bookmark = $APP->get_widget('location')->entry->get_text;
	add_bookmark_item($bookmark);
	push(@BOOKMARKS, $bookmark);
	$APP->get_widget('add_bookmark_item')->set_sensitive($APP->get_widget('location')->entry->get_text ne '' && !defined($BOOKMARK_ITEMS->{$APP->get_widget('location')->entry->get_text}));
	return 1;
}

sub new_window {
	system("$0 &");
	return 1;
}

### the next three functions are all used together, in various places: context
### menus for the navigation buttons, the bookmarks menu, and so on:

### append an item to the bookmarks menu. keep a reference in $BOOKMARK_ITEMS
### so that if the bookmark is deleted we can easily remove it from the menu:
sub add_bookmark_item {
	my $bookmark = shift;
	my $item = document_menu_item($bookmark);
	$item->show_all;
	$BOOKMARK_ITEMS->{$bookmark} = $item;
	$APP->get_widget('bookmarks_menu')->get_submenu->append($item);
	return 1;
}

### create a menu item for a document. they all have the same behaviour:
sub document_menu_item {
	my $document = shift;
	my $item = Gtk2::ImageMenuItem->new_with_mnemonic($document =~ /\// ? (split(/\//, $document))[-1] : $document);
	$item->set_image(Gtk2::Image->new_from_pixbuf($PAGE_PBF));
	$item->signal_connect('activate', sub { link_clicked(undef, $document) });
	$TIPS->set_tip($item, sprintf(gettext("Go to '%s'"), $document));
	return $item;
}

### create a popup menu for a list of documents:
sub create_popup_menu {
	my ($menu, @docs) = @_;
	foreach my $child ($menu->get_children) {
		$menu->remove($child);
		$child->destroy;
	}
	foreach my $doc (@docs) {
		my $item = document_menu_item($doc);
		$menu->append($item);
	}
	$menu->show_all;
	return 1;
}

sub reload_index {
	set_ui_busy();
	$APP->get_widget('main_window')->set_sensitive(undef);
	Gtk2->main_iteration while(Gtk2->events_pending);
	$viewer->reinitialize_db;
	save_cache();
	$APP->get_widget('main_window')->set_sensitive(1);
	set_ui_waiting();
}

sub show_help {
	set_location($0);
}

sub view_source {
	$APP->get_widget('view_source_text')->get_buffer->set_text($viewer->parser->source);
	$APP->get_widget('view_source_window')->show_all;
}

sub view_source_window_hide {
	$APP->get_widget('view_source_window')->hide;
	return 1;
}

sub show_display_preferences_dialog {
	$APP->get_widget('variable_font_chooser')->set_font_name($OPTIONS->{variable_font});
	$APP->get_widget('fixed_font_chooser')->set_font_name($OPTIONS->{fixed_font});

	$APP->get_widget('header_color_chooser')->set_color(Gtk2::Gdk::Color->parse($OPTIONS->{header_color}));
	$APP->get_widget('monospace_color_chooser')->set_color(Gtk2::Gdk::Color->parse($OPTIONS->{preformat_color}));

	$APP->get_widget('display_preferences_dialog')->show;
	return 1;
}

sub close_display_preferences_dialog {
	$APP->get_widget('display_preferences_dialog')->hide;
	return 1;
}

sub display_preferences_dialog_response {
	if ($_[1] eq 'ok') {
		$OPTIONS->{variable_font} = $APP->get_widget('variable_font_chooser')->get_font_name;
		$OPTIONS->{fixed_font} = $APP->get_widget('fixed_font_chooser')->get_font_name;

		$OPTIONS->{toolbar_style} = $TOOLBAR_STYLES{$toolbar_style_combo->get_active_text};

		$OPTIONS->{header_color} = sprintf('#%02X%02X%02X',
			$APP->get_widget('header_color_chooser')->get_color->red / 256,
			$APP->get_widget('header_color_chooser')->get_color->green / 256,
			$APP->get_widget('header_color_chooser')->get_color->blue / 256,
		);

		$OPTIONS->{preformat_color} = sprintf('#%02X%02X%02X',
			$APP->get_widget('monospace_color_chooser')->get_color->red / 256,
			$APP->get_widget('monospace_color_chooser')->get_color->green / 256,
			$APP->get_widget('monospace_color_chooser')->get_color->blue / 256,
		);

		setup_display();
	}
	$APP->get_widget('display_preferences_dialog')->hide;
	return 1;
}

sub setup_display {
	$viewer->modify_font(Gtk2::Pango::FontDescription->from_string($OPTIONS->{variable_font}));
	$APP->get_widget('view_source_text')->modify_font(Gtk2::Pango::FontDescription->from_string($OPTIONS->{fixed_font}));
	$APP->get_widget('toolbar')->set_style($OPTIONS->{toolbar_style});
	($OPTIONS->{toolbar_style} eq 'icons' ? $APP->get_widget('location_label')->hide : $APP->get_widget('location_label')->show);
	$viewer->get_buffer->get_tag_table->lookup('monospace')->set('font' => $OPTIONS->{fixed_font});
	$viewer->get_buffer->get_tag_table->lookup('monospace')->set('foreground' => $OPTIONS->{preformat_color});
	$viewer->get_buffer->get_tag_table->lookup('typewriter')->set('font' => $OPTIONS->{fixed_font});
	$viewer->get_buffer->get_tag_table->lookup('head1')->set('foreground' => $OPTIONS->{header_color});
	$viewer->get_buffer->get_tag_table->lookup('head2')->set('foreground' => $OPTIONS->{header_color});
	$viewer->get_buffer->get_tag_table->lookup('head3')->set('foreground' => $OPTIONS->{header_color});
	$viewer->get_buffer->get_tag_table->lookup('head4')->set('foreground' => $OPTIONS->{header_color});
}

sub show_print_dialog {
}

sub generate_pod_index {
	my ($name, @docs) = @_;
	my $pod = sprintf("=pod\n\n=head1 %s\n\n=over\n\n%s\n\n", $name, sprintf(gettext('Documents under %s:'), $name));
	foreach my $doc (sort(@docs)) {
		$pod .= sprintf("=item L<%s>\n\n", $doc);
	}
	return $pod . "=back\n\n=cut\n\n";
}

sub set_status {
	$APP->get_widget('status')->push($APP->get_widget('status')->get_context_id('Default'), shift);
}

__END__

=pod

=head1 NAME

podbrowser - a Perl documentation browser for GNOME

PodBrowser is a more feature-complete version of podviewer, which comes with
Gtk2::Ex::PodViewer.

=head1 SYNTAX

B<podbrowser> [F<location>]

=head1 DESCRIPTION

PodBrowser is a documentation browser for Perl. You can view the documentation
for Perl's builtin functions, its "perldoc" pages, pragmatic modules and the
default and user-installed modules.

=head1 OPTIONS

F<location> If an argument is specified this argument is loaded as location.

=head1 PREREQUISITES

In addition to a number of modules bundles with recent Perl releases,
PodBrowser needs the following:

=over

=item L<Gtk2> and the C<gtk2> library (C<gtk2> E<gt>= 2.8.0 is required)

=item The C<gnome-icon-theme> package (version E<gt>= 2.10.0 is required)

=item L<Gtk2::GladeXML> and the C<libglade> library

=item L<Locale::gettext> and the C<gettext> library

=item L<Gtk2::Ex::PodViewer>

=item L<Pod::Simple::Search>

=item L<URI::Escape>

=back

=head1 AUTHOR

(C) Gavin Brown. Original manpage by Florian Ragwitz.

The C<html2ps-podbrowser> script is a copy of the original C<html2ps> script which
is (C) Jan KE<auml>rrman.

=cut
