# Springboard

A server implementation of the [Spring83 Protocol](https://github.com/robinsloan/spring-83). Spring83 is a protocol which aspires to be:

> **Simple**. This means the protocol is easy to understand and implement, even for a non-expert programmer.
>
> **Expressive**. This means the protocol embraces the richness, flexibility, and chaos of modern HTML and CSS. It does not formalize interactions and relationships into database schemas.
>
> **Predictable**. This means boards holds their place, maintaining a steady presence. It means also that clients only receive the boards they request, when they request them; there is no mechanism by which a server can "push" an unsolicited board.

Spring83 is a client/server protocol. Springboard, in its current form, is an implementation of the server portion of the protocol.

In addition to a server implementation, Springboard comes with a few helpful tools for working with Spring83 boards.

Springboard is currently running at [springboard.blog](springboard.blog).

## Installation

Springboard is built with the Zig programming language, and requires a Zig compiler from [master](https://github.com/ziglang/zig) to be built. Springboard can be built with one simple command:

```bash
$ zig build
```

This will build Springboard in Debug mode. If you are planning on using Springboard to generate a new key, it's recommended to build it in Release-Fast mode, like this:

```bash
$ zig build -Drelease-fast
```

This will speed up the key generation process by a very significant degree.

## Key Mode

Before one can post a board to a Spring83 server they must generate a public/private key pair. This key pair will be used to sign the content of the board before it is uploaded. The public part is also used to identify boards.

Spring83 requires that the key pairs conform to certain rules, which are enumerated [here](https://github.com/robinsloan/spring-83/blob/main/draft-20220629.md#generating-conforming-keys). Springboard can generate conforming keys for one to use with the following command:

```bash
$ springboard key
```

Due to the cryptographic nature of the key generation process, generating the keys can take several minutes.

## Sign Mode

Springboard can sign boards using a pre-generated key pair. The process is straightforward:

1. Generate a key and save the entire hex-encoded value to a file, on a single line.
2. Create your board
3. Run `springboard sign --board <board file name> --key-file <key file name>`

Spring83 boards must contain a timestamp element in order to determine the board's validity. Springboard's `sign` function can append the current timestamp to the board, if desired, using the optional `--append-timestamp` flag.

## Push Mode

Springboard can push boards to a Spring83 server. All you need is a valid board and a file containing your secret key! Once you have these, you can push the board using this command:

```bash
$ springboard push --board <board file> --key-file <key file> --server <server domain> --port <server port>
```

## Server Mode

This mode runs a Spring83 server. The entire server spec API has been implemented at this time, though it's still in early stages of development and may not be stable.

To run a Spring83 server, simply run:

```bash
$ springboard server --port <port>
```
