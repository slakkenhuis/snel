# This adds recipes for uploading the destination directory to a server, via
# FTP or SSH.

ifeq (,$(filter %/pandoc.mk pandoc.mk,$(MAKEFILE_LIST)))
$(error The main pandoc.mk module was not loaded)
endif

ifndef USER
	$(error Variable USER is not set)
endif
ifndef HOST
	$(error Variable HOST is not set)
endif
PROTOCOL?=ssh
REMOTE_DIR?=/home/$(USER)/public_html
ifndef PORT
ifeq ($(PROTOCOL),ssh)
	PORT := 22
else
	PORT := 20
endif
endif

upload: upload-$(PROTOCOL)

upload-ftp: 
	read -s -p 'FTP password: ' password && \
	lftp -u "$(USER),$$password" -p "$(PORT)" \
	-e 'mirror --reverse --only-newer --verbose --dry-run --exclude "$(CACHE)" "$(DEST)" $(REMOTE_DIR)"' \
	"$(HOST)"

upload-ssh:
	rsync -e "ssh -p $(PORT)" \
		--recursive --times --copy-links --verbose --progress \
		--exclude="$(CACHE)" \
		"$(DEST)/" $(USER)@$(HOST):'$(REMOTE_DIR)/'

.PHONY: upload upload-ftp upload-ssh
