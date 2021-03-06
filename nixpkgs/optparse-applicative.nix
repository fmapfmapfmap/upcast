{ cabal, ansiWlPprint, transformers, transformersCompat }:

cabal.mkDerivation (self: {
  pname = "optparse-applicative";
  version = "0.11.0.1";
  sha256 = "0jdzajj9w0dghv751m59l3imzm2x9lx9cqb6094mncnx8k6cf6f9";
  buildDepends = [ ansiWlPprint transformers transformersCompat ];
  meta = {
    homepage = "https://github.com/pcapriotti/optparse-applicative";
    description = "Utilities and combinators for parsing command line options";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
  };
})
