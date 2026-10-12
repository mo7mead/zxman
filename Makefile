.DEFAULT_GOAL := run
.PHONY: install run public clean help

install:            ## Install dependencies (webrick)
	bundle install

run:                ## Start zxman (the request catcher)
	bundle exec ruby server.rb

public:             ## Start without the cloudflared tunnel
	TUNNEL=0 bundle exec ruby server.rb

clean:              ## Remove captured requests and logs
	rm -rf hits requests.log

help:               ## List the available targets
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-10s\033[0m %s\n", $$1, $$2}'
