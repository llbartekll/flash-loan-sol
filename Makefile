-include .env
export

deploy:
	forge script script/Deploy.s.sol --rpc-url optimism --broadcast --verify

build:
	forge build

test:
	forge test

fmt:
	forge fmt
