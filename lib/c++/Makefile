PREFIX ?= /usr
EXEC_PREFIX ?= $(PREFIX)
LIBDIR ?= $(EXEC_PREFIX)/lib/$(DEB_HOST_MULTIARCH)
INCLUDEDIR ?= $(EXEC_PREFIX)/include

TARGET := libvplaned-client.so.1
TARGET_LINK := libvplaned-client.so
PKG_CONFIG := vplaned-client.pc
CPP_SOURCES := vplaned-client.cpp
CPP_HEADERS := vplaned-client.hpp
CPP_OBJS := $(patsubst %.cpp,%.oxx,$(CPP_SOURCES))

LIBS += $(shell pkg-config --libs jansson)
LIBS += $(shell pkg-config --libs protobuf)
LIBS += $(shell pkg-config --libs libzmq)
LIBS += $(shell pkg-config --libs vyatta-dataplane-proto)
LIBS += $(shell pkg-config --libs vyatta-controller-proto)
LIBS += -lb64

CXXFLAGS += -std=gnu++11 -g -fPIC
CXXFLAGS += $(shell pkg-config --cflags jansson)
CXXFLAGS += $(shell pkg-config --cflags protobuf)
CXXFLAGS += $(shell pkg-config --cflags libzmq)
CXXFLAGS += $(shell pkg-config --cflags vyatta-dataplane-proto)
CXXFLAGS += $(shell pkg-config --cflags vyatta-controller-proto)

all: $(TARGET) $(TARGET_LINK) $(PKG_CONFIG)

install: all
	mkdir -p $(DESTDIR)/$(LIBDIR)
	install $(TARGET) $(DESTDIR)/$(LIBDIR)
	cp -P $(TARGET_LINK) $(DESTDIR)/$(LIBDIR)
	mkdir -p $(DESTDIR)/$(LIBDIR)/pkgconfig
	install -m 644 $(PKG_CONFIG) $(DESTDIR)/$(LIBDIR)/pkgconfig
	mkdir -p $(DESTDIR)/$(INCLUDEDIR)
	install -m 644 $(CPP_HEADERS) $(DESTDIR)/$(INCLUDEDIR)

%.oxx: %.cpp %.hpp
	g++ $(CXXFLAGS) $(CPPFLAGS) -c -o $@ $<

$(TARGET): $(CPP_OBJS)
	g++ -shared -fPIC $(LDFLAGS) -Wl,-soname,$@ -o $@ $(LIBS) $^

$(TARGET_LINK): $(TARGET)
	ln -s $(TARGET) $(TARGET_LINK)

$(PKG_CONFIG):
	echo 'prefix=$(PREFIX)' >> $@
	echo 'exec_prefix=$${prefix}' >> $@
	echo 'libdir=$${exec_prefix}/lib/$(DEB_HOST_MULTIARCH)' >> $@
	echo 'includedir=$${exec_prefix}/include' >> $@
	echo '' >> $@
	echo 'Name: vplaned-client' >> $@
	echo 'Description: vplaned client library' >> $@
	echo 'Version: 1.0.0' >> $@
	echo 'Requires: libzmq, protobuf, vyatta-dataplane-proto, vyatta-controller-proto' >> $@
	echo 'Libs: -L$${libdir} -lvplaned-client' >> $@
	echo 'Cflags: -I$${includedir}' >> $@
