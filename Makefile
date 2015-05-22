PROJECT = wschat

DEPS = cowboy lager jsx cqerl ex_apns
dep_cowboy = git https://github.com/ninenines/cowboy 1.0.0
dep_lager = https://github.com/basho/lager.git 
dep_jsx = git https://github.com/talentdeficit/jsx.git v1.4.5
dep_ex_apns = https://github.com/extend/ex_apns.git
dep_cqerl = git https://github.com/matehat/cqerl.git v0.8.0

export SKIP_DIALYZER=true

include erlang.mk

deps::
	sed -i 's/\(stdlib\)/\1,ssl/' deps/ranch/ebin/ranch.app

	