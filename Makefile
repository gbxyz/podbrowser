# $Id: Makefile,v 1.4 2005/10/05 10:07:40 jodrell Exp $
NAME=podbrowser
PREFIX=/usr/local
BINDIR=$(PREFIX)/bin
DATADIR=$(PREFIX)/share
ICONDIR=$(DATADIR)/icons/hicolor/48x48/apps
MANDIR=$(DATADIR)/man/man1

all: podbrowser

podbrowser:
	@mkdir -p build

	perl -ne 's!\@PREFIX\@!$(PREFIX)!g ; s!\@LIBDIR\@!$(LIBDIR)!g ; print' < $(NAME).pl > build/$(NAME)
	pod2man $(NAME).pl | gzip -c > build/$(NAME).1.gz

install:
	mkdir -p	$(BINDIR) \
			$(DATADIR)/$(NAME) \
			$(DATADIR)/applications \
			$(ICONDIR) \
			$(MANDIR)
	install -m 0644 $(NAME).glade		$(DATADIR)/$(NAME)/
	install -m 0644 $(NAME).png		$(ICONDIR)/
	install -m 0644 $(NAME).desktop		$(DATADIR)/applications/
	install -m 0644 build/$(NAME).1.gz	$(MANDIR)/
	install -m 0755 build/$(NAME)		$(BINDIR)/$(NAME)
	install -m 0755 html2ps-$(NAME)		$(BINDIR)/html2ps-$(NAME)

po: $(NAME).pl $(NAME).glade
	xgettext -kgettext -lperl $(NAME).pl
	sed -i s/charset=CHARSET/charset=UTF-8/ messages.po
	xgettext -lGlade -j $(NAME).glade

mo:
	if test -d "locale/$$LANG/LC_MESSAGES"; then \
		echo "locale/$$LANG/LC_MESSAGES exists"; \
	else \
		mkdir -p "locale/$$LANG/LC_MESSAGES"; \
	fi
	msgfmt -o "locale/$$LANG/LC_MESSAGES/$(NAME).mo" "$(NAME).$$LANG.po"

clean:
	rm -rf build
