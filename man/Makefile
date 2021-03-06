ifndef CHPL_MAKE_HOME
export CHPL_MAKE_HOME=$(shell pwd)/..
endif

PROGRAM = chpl
CHPLDOC = chpldoc

MANPAGE = man1/$(PROGRAM).1
CHPLDOC_MANPAGE = man1/$(CHPLDOC).1
TARGETS = $(MANPAGE) $(PROGRAM).pdf $(CHPLDOC).pdf

PYTHON_VERSION_DIR = py$(shell $(CHPL_MAKE_HOME)/util/chplenv/chpl_python_version.py)

RST2MAN = $(CHPL_MAKE_HOME)/third-party/chpl-venv/install/*/$(PYTHON_VERSION_DIR)/chpl-virtualenv/bin/rst2man.py

STARS = \*\*\*\*\*

default: echoman $(MANPAGE)

echoman: FORCE
	@echo $(STARS) ./ $(STARS)

all: $(TARGETS)

chpldoc: $(CHPLDOC_MANPAGE)

clean:
	rm $(TARGETS)

man1/%.1: %.rst Makefile
	mkdir -p $(shell dirname $@)
	sed "/conf$</r conf$<" $< > $<.tmp
	$(RST2MAN) $<.tmp > $@
	rm -f $<.tmp

%.ps: man1/%.1
	groff -man $< > $@

%.html: man1/%.1
	groff -T html -man $< > $@

%.pdf: %.ps
	ps2pdf $< $@

FORCE:
