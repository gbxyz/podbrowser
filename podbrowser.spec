Name:		podbrowser
Summary:	A full-featured Perl Documentation Browser.
Version:	0.10
Release:	1
Epoch:		0
Group:		Applications/Programming
License:	GPL
URL:		http://jodrell.net/projects/podbrowser
Packager:	Gavin Brown <gavin.brown@uk.com>
Vendor:		http://jodrell.net/
Source:		http://jodrell.net/download.html?file=/files/%{name}/%{name}-%{version}.tar.gz
BuildRoot:	%{_tmppath}/root-%{name}-%{version}
Prefix:		%{_prefix}
AutoReq:	no
BuildArch:	noarch
BuildRequires:	perl >= 5.8.0, gettext
Requires:	gtk2 >= 2.8.0, libglade2, gnome-icon-theme > 2.10, gettext, perl >= 5.8.0, perl-URI, perl-Gtk2, perl-Gtk2-GladeXML >= 1.001, perl-gettext, perl-Gtk2-Ex-PodViewer >= 0.14, perl-Pod-Simple, perl-Gtk2-Ex-Simple-List, perl-Gtk2-Ex-PrintDialog

%description
PodBrowser is a documentation browser for Perl. You can view the documentation
for Perl's builtin functions, its "perldoc" pages, pragmatic modules and the
default and user-installed modules.

%prep
%setup

%build
make PREFIX=%{_prefix}

%install
rm -rf %{buildroot}
%makeinstall PREFIX=%{buildroot}%{_prefix}

%clean
rm -rf %{buildroot}

%files
%defattr(-,root,root,0755)
%doc README COPYING
%{_bindir}/*
%{_datadir}/*
