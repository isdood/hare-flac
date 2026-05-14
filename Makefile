.POSIX:

HARE = hare
HARECFLAGS =

.PHONY: all flac-enc test clean

all: flac-enc

flac-enc:
	$(HARE) build $(HARECFLAGS) -o flac-enc cmd/flac-enc/

test:
	$(HARE) test src/wav/

clean:
	rm -f flac-enc
