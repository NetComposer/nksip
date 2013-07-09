PROJECT = nksip
DIALYZER = dialyzer
REBAR = ./rebar

all: app

deps:
	@$(REBAR) get-deps

app: deps
	@$(REBAR) compile

clean: clean-docs clean-logs
	@$(REBAR) clean
	rm -f erl_crash.dump

clean-logs:
	rm -rf nksip/log 
	rm -rf samples/nksip_loadtest/log 
	rm -rf samples/nksip_pbx/log 
	rm -rf samples/nksip_tutorial/log 

docs: clean-docs
	@$(REBAR) doc skip_deps=true

clean-docs:
	rm -f nksip/doc/*.css nksip/doc/*.html \
	      nksip/doc/*.png nksip/doc/edoc-info
	rm -f samples/nksip_loadtest/doc/*.css samples/nksip_loadtest/doc/*.html \
	      samples/nksip_loadtest/doc/*.png samples/nksip_loadtest/doc/edoc-info
	rm -f samples/nksip_pbx/doc/*.css samples/nksip_pbx/doc/*.html \
	      samples/nksip_pbx/doc/*.png samples/nksip_pbx/doc/edoc-info
	rm -f samples/nksip_tutorial/doc/*.css samples/nksip_tutorial/doc/*.html \
	      samples/nksip_tutorial/doc/*.png samples/nksip_tutorial/doc/edoc-info

tests: app eunit

eunit:
	@$(REBAR) eunit skip_deps=true

build-plt:
	@$(DIALYZER) --build_plt --output_plt .$(PROJECT).plt \
		--apps kernel stdlib sasl tools inets crypto public_key ssl

dialyze: app
	@$(DIALYZER) nksip/ebin/nksip*.beam --plt .$(PROJECT).plt \
	-Werror_handling  #-Wunmatched_returns -Wrace_conditions -Wunderspecs

shell: 
	erl -config samples/nksip_loadtest/priv/app.config \
		-args_file samples/nksip_loadtest/priv/vm.args 

tutorial: 
	erl -config samples/nksip_tutorial/priv/app.config \
		-args_file samples/nksip_tutorial/priv/vm.args 

loadtest: app
	erl -config samples/nksip_loadtest/priv/app.config \
		-args_file samples/nksip_loadtest/priv/vm.args -s nksip_loadtest 

pbx: app
	erl -config samples/nksip_pbx/priv/app.config \
		-args_file samples/nksip_pbx/priv/vm.args -s nksip_pbx

build_tests:
	erlc -pa nksip/ebin -pa deps/lager/ebin -o nksip/ebin -I include \
	+export_all +debug_info nksip/test/*.erl


