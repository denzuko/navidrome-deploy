BIN     := navidrome-deploy
PREFIX  ?= /usr/local
SOURCES := navidrome.asd navidrome-deploy.ros $(wildcard src/*.lisp)

all: build

build: $(BIN)

$(BIN): $(SOURCES)
	ros dump executable navidrome-deploy.ros -o $(BIN)

render: $(BIN)
	./$(BIN) --render

install: $(BIN)
	install -d $(DESTDIR)$(PREFIX)/sbin
	install -m 0755 $(BIN) $(DESTDIR)$(PREFIX)/sbin/$(BIN)

clean:
	rm -f $(BIN)

.PHONY: all build render install clean
