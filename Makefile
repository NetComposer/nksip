APP = nksip
REBAR = rebar3
AFLAGS = "-kernel shell_history enabled -kernel logger_sasl_compatible true"

.PHONY: rel stagedevrel package version all tree shell

all: version compile


version:
	@echo "$(shell git symbolic-ref HEAD 2> /dev/null | cut -b 12-)-$(shell git log --pretty=format:'%h, %ad' -1)" > $(APP).version


version_header: version
	@echo "-define(VERSION, <<\"$(shell cat $(APP).version)\">>)." > include/$(APP)_version.hrl


clean:
	$(REBAR) clean


rel:
	$(REBAR) release


compile:
	$(REBAR) compile


tests:
	$(REBAR) eunit


dialyzer:
	$(REBAR) dialyzer


xref:
	$(REBAR) xref


upgrade:
	$(REBAR) upgrade
	make tree


update:
	$(REBAR) update


tree:
	$(REBAR) tree | grep -v '=' | sed 's/ (.*//' > tree


tree-diff: tree
	git diff test -- tree


docs:
	$(REBAR) edoc


shell:
	ERL_AFLAGS=$(AFLAGS) $(REBAR) shell --config config/shell.config --name $(APP)@127.0.0.1 --setcookie nk --apps $(APP)

remsh:
	erl -name remsh@127.0.0.1 -setcookie nk -remsh $(APP)@127.0.0.1

remsh2:
	erl -name remsh2@127.0.0.1 -setcookie nk -remsh $(APP)@127.0.0.1
