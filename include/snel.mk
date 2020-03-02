# TODO: Perhaps follow https://tech.davis-hansson.com/p/make/

# Installation directories
PREFIX := /usr/local
INCLUDE_DIR := $(PREFIX)/include
SHARE_DIR := $(PREFIX)/share/snel

# Location of snel.mk makefile
BASE_DIR := $(patsubst %/,%,$(dir $(abspath $(lastword $(MAKEFILE_LIST)))))

# If installed in $PREFIX/include, we find other assets in $PREFIX/share/snel.
# Otherwise, we find them relative to the current makefile
ifeq ($(BASE_DIR),$(INCLUDE_DIR))
    ASSET_DIR := $(SHARE_DIR)
    JQ_DIR := $(SHARE_DIR)
    PANDOC_DIR := $(SHARE_DIR)/pandoc
else
    ASSET_DIR := $(BASE_DIR)/../share
    JQ_DIR := $(BASE_DIR)/../share
    PANDOC_DIR := $(BASE_DIR)/../share/pandoc
endif

# Source and destination directories, and FTP credentials. These are
# expected to be changed in the `make` call or before the `include` statement.
ifndef SRC
    SRC := .
endif
ifndef DEST
    DEST := build
endif
ifndef CACHE
    CACHE := $(DEST)/cache
endif
ifndef USER
    USER := user
endif
ifndef HOST
    HOST := host
endif
ifndef REMOTE_DIR
    REMOTE_DIR := /home/user/public_html
endif
ifndef IGNORE
    IGNORE=Makefile .git .gitignore
endif

# Find source files
SOURCE_FILES = $(shell \
    find -L "$(SRC)"  $(patsubst %,-name '%' -prune -o,$(IGNORE)) -iname '*.md' -print \
)

# Metadata and extra targets are collected for each source in a corresponding file
INFO_FILES = $(patsubst $(SRC)/%,$(CACHE)/%.info.json,$(SOURCE_FILES))

# Output files
ASSET_FILES = \
    $(DEST)/index.html \
    $(DEST)/style.css \
    $(DEST)/favicon.ico \
    $(DEST)/apple-touch-icon.png

##############################################################################
# Phony targets

# We need two seperate runs: first to build the index, then to build the
# context which is based on said index. Con: this will build the index twice if
# run with `make -B`
site:
	$(MAKE) index
	$(MAKE) content

all: site
	$(MAKE) clean upload

# The cache is built on the first run: we read the metadata of all files to
# build an index
index: $(CACHE)/targets.txt

# On the second run, we build the actual published documents and files that
# those documents refer to
content: $(shell cat $(CACHE)/targets.txt 2>/dev/null)

# Optionally, remove all files in $(DEST) that are no longer targeted
clean: $(CACHE)/targets.txt
	@bash -i -c 'read -p "Operation might remove files in \"$(DEST)\". Continue? [y/N]" -n 1 -r; \
	    [[ $$REPLY =~ ^[Yy]$$ ]] || exit 1'
	@echo
	find "$(DEST)" -type f -a -not -path '$(CACHE)/*' \
	    | grep --fixed-strings --line-regexp --invert-match --file=$< \
	    | xargs --no-run-if-empty rm

# Upload the result
upload: 
	read -s -p 'FTP password: ' password && \
	lftp -u $(USER),$$password -e \
	"mirror --reverse --only-newer --verbose --dry-run --exclude $(CACHE) $(DEST) $(REMOTE)" \
	$(HOST)


.PHONY: all site index content clean upload



##############################################################################
# Resources

# If `snel` is installed globally, the stylesheet and favicon should be already
# available in `$PREFIX/share/snel`; otherwise they should be compiled.
ifeq ($(BASE_DIR),$(INCLUDE_DIR))
$(DEST)/%: $(ASSET_DIR)/%
	@-mkdir -p $(@D)
	cp $< $@

else
# Stylesheet
$(DEST)/style.css: $(ASSET_DIR)/style.scss
	@-mkdir -p $(@D)
	sassc --style compressed $< $@

# Favicon as bitmap
$(DEST)/favicon.ico: $(ASSET_DIR)/favicon.svg
	@-mkdir -p $(@D)
	convert $< -transparent white -resize 16x16 -level '0%,100%,0.6' $@

# Icon for bookmark on Apple devices
$(DEST)/apple-touch-icon.png: $(ASSET_DIR)/favicon.svg
	@-mkdir -p $(@D)
	convert -density 1200 -resize 140x140 -gravity center -extent 180x180 \
	    	+level-colors '#fff,#711' -colors 16 \
		-compress Zip -define 'png:format=png8' -define 'png:compression-level=9' \
		$< $@
endif


##############################################################################
# Indexing


# Record document metadata for each document
$(CACHE)/%.md.meta.json: $(SRC)/%.md $(PANDOC_DIR)/metadata.json $(JQ_DIR)/index.jq
	@-mkdir -p "$(@D)"
	@echo "Determining document metadata for \"$<\"…" 1>&2
	@pandoc --template='$(PANDOC_DIR)/metadata.json' \
	    --to=plain \
	    $< \
	    | jq '{"meta":.}' \
	    > $@

# Record extra targets for each document
$(CACHE)/%.md.targets.json: $(SRC)/%.md 
	@-mkdir -p "$(@D)"
	@echo "Determining indirect targets  for \"$<\"…" 1>&2
	@pandoc -f markdown -t json -i $< \
	    | jq -r '{"targets":[ .blocks[] | recurse(.c?[]?) | select(.t? == "Image") | .c[2][0] | select(test("^[a-z]+://") | not) ]}' \
	    > $@

# Combination of metadata + targets
$(CACHE)/%.md.info.json: $(CACHE)/%.md.meta.json $(CACHE)/%.md.targets.json 
	@-mkdir -p "$(@D)"
	@jq \
	    -L"$(JQ_DIR)" \
	    --arg path "$(patsubst $(CACHE)/%.md.info.json,%.md,$@)" \
	    --slurp \
	    'include "index"; add | tree(["."] + ($$path | split("/")))' \
	    $^ \
	    > $@

# Overview of final targets
$(CACHE)/targets.txt: $(CACHE)/index.json
	@echo "Aggregating targets…" 1>&2
	@jq \
	    -L"$(JQ_DIR)" \
	    --arg dest "$(DEST)/" \
	    -r 'include "index"; targets | ltrimstr("./") | $$dest + .' \
	    < $< \
	    > $@
	@for F in $(ASSET_FILES); do echo $$F >> $@; done

# Overview of files & directories, without metadata
$(CACHE)/filetree.json: $(SOURCE_FILES)
	@-mkdir -p $(@D)
	@echo "Generating file tree…" 1>&2
	@tree -JDpi --du --timefmt '%s' --dirsfirst \
	    -I '$(subst $() $(),|,$(IGNORE))' \
	    | jq '.[0]' \
	    > $@

# Overview of files & directories with metadata, readable for index template
$(CACHE)/index.json: $(JQ_DIR)/index.jq \
	    $(CACHE)/filetree.json \
	    $(INFO_FILES) \
	    $(wildcard $(SRC)/index.base.json)
	@-mkdir -p $(@D)
	@echo "Aggregating file index…" 1>&2
	@jq  -L$(JQ_DIR) --slurp \
	    'include "index"; index' \
	    $(filter %.json, $^) \
	    > $@

# Generate static index page 
$(DEST)/index.html: $(PANDOC_DIR)/index.html $(PANDOC_DIR)/nav.html $(CACHE)/index.json
	@-mkdir -p $(@D)
	@echo "Generating table of contents…" 1>&2
	@echo | pandoc \
	    --template="$(PANDOC_DIR)/index.html" \
	    --metadata-file "$(CACHE)/index.json" \
	    --metadata title="Table of contents" \
	    > $@



##############################################################################
# Documents

# Create HTML documents
# The following targets are required once but do not influence the build of this
# target: $(DEST)/style.css $(DEST)/favicon.ico
$(DEST)/%.html: \
		$(SRC)/%.md \
		$(PANDOC_DIR)/page.html \
		$(wildcard $(SRC)/*.bib) 
	@echo "Generating document \"$@\"..." 1>&2
	@-mkdir -p "$(@D)"
	@-mkdir -p "$(patsubst $(DEST)/%,$(CACHE)/%,$(@D))"
	@pandoc  \
		--metadata path='$(shell realpath $(@D) --relative-to $(DEST) --canonicalize-missing)' \
		--metadata root='$(shell realpath $(DEST) --relative-to $(@D) --canonicalize-missing)' \
		--metadata index='$(shell realpath $(DEST)/index.html --relative-to $(@D) --canonicalize-missing)' \
		--metadata favicon='$(shell realpath $(DEST)/favicon.ico --relative-to $(@D) --canonicalize-missing)' \
		--metadata stylesheet='$(shell realpath $(DEST)/style.css --relative-to $(@D) --canonicalize-missing)' \
		--from markdown+smart+fenced_divs+inline_notes+table_captions \
		--to html5 \
		--standalone \
		--table-of-contents \
		--toc-depth=3 \
		--template '$(PANDOC_DIR)/page.html' \
		$(foreach F,\
			$(filter %.css, $^),\
			--css='$(F)' \
		) \
		--filter pandoc-citeproc \
		$(foreach F,\
			$(filter %.bib, $^),\
			--bibliography='$(F)' \
		)\
		--shift-heading-level-by=1 \
		--ascii \
		--strip-comments \
		--email-obfuscation=references \
		--highlight-style=kate \
		$< \
		$(filter %/metadata.yaml, $^) \
		| sed ':a;N;$$!ba;s|>\s*<|><|g' \
		> $@


# Create PDF documents
$(DEST)/%.pdf: $(SRC)/%.md $(PANDOC_DIR)/page.html $(DEST)/style.css
	@echo "Generating document \"$@\"..." 1>&2
	pandoc \
	    --shift-heading-level-by=1 \
	    --pdf-engine=weasyprint \
	    --template '$(PANDOC_DIR)/page.html' \
	    --css '$(DEST)/style.css' \
	    --to pdf \
	    $< \
	| ps2pdf -dOptimize=true -dUseFlateCompression=true - $@


##########################################################################$$$$
# Generic recipes

# Optimised SVG
$(DEST)/%.svg: $(SRC)/%.svg
	@-mkdir -p $(@D)
	svgo --input=$< --output=$@

$(DEST)/%.png: $(SRC)/%.jpg
	@-mkdir -p $(@D)
	convert $< \
		-resize '600x' \
		-dither FloydSteinberg \
		-colorspace gray \
		-colors 8 \
		-normalize \
		-define png:color-type=3 \
        -define png:compression-level=9  \
		-define png:format=png8 \
		-strip \
		$@
	optipng $@
	@echo "Original size $$(ls -sh $< | cut -d' ' -f1)."
	@echo "Compressed to $$(ls -sh $@ | cut -d' ' -f1)."


$(DEST)/%.gif: $(SRC)/%.jpg
	@-mkdir -p $(@D)
	convert $< \
		-resize '400x' \
		-colorspace gray \
		-colors 12 \
		-normalize \
		-dither FloydSteinberg \
		-strip \
		$@
	@echo "Original size $$(ls -sh $< | cut -d' ' -f1)."
	@echo "Compressed to $$(ls -sh $@ | cut -d' ' -f1)."


$(DEST)/%.jpg: $(SRC)/%.jpg
	@-mkdir -p $(@D)
	convert  $< \
		-resize '600x' \
		-quality '60%' \
		$@
	@echo "Original size $$(ls -sh $< | cut -d' ' -f1)."
	@echo "Compressed to $$(ls -sh $@ | cut -d' ' -f1)."

# Any file in the source is also available at the destination
$(DEST)/%: $(SRC)/%
	@-mkdir -p $(@D)
	-ln -s --relative $< $@
