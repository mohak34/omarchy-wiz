# Builds the bulb helper the widget runs from bin/.
bin/wiz: helper/*.go helper/go.mod
	cd helper && go build -trimpath -ldflags="-s -w" -o ../bin/wiz .

.PHONY: clean
clean:
	rm -rf bin
