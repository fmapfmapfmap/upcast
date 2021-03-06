{ cabal, aeson, attoparsec, base16Bytestring, base64Bytestring
, blazeBuilder, byteable, caseInsensitive, cereal, conduit
, conduitExtra, cryptohash, dataDefault, errors, filepath
, httpConduit, httpTypes, liftedBase, monadControl, mtl, network
, QuickCheck, quickcheckInstances, resourcet, safe, scientific
, tagged, tasty, tastyQuickcheck, text, time, transformers
, unorderedContainers, utf8String, vector, xmlConduit
}:

cabal.mkDerivation (self: {
  pname = "aws";
  version = "0.10.2";
  sha256 = "15yr06z54wxnl37a94515ajlxrb7z9kii5dd0ssan32izh4nfrl2";
  isLibrary = true;
  isExecutable = true;
  doCheck = false;
  buildDepends = [
    aeson attoparsec base16Bytestring base64Bytestring blazeBuilder
    byteable caseInsensitive cereal conduit conduitExtra cryptohash
    dataDefault filepath httpConduit httpTypes liftedBase monadControl
    mtl network resourcet safe scientific tagged text time transformers
    unorderedContainers utf8String vector xmlConduit
  ];
  testDepends = [
    aeson errors mtl QuickCheck quickcheckInstances tagged tasty
    tastyQuickcheck text transformers
  ];
  meta = {
    homepage = "http://github.com/aristidb/aws";
    description = "Amazon Web Services (AWS) for Haskell";
    license = self.stdenv.lib.licenses.bsd3;
    platforms = self.ghc.meta.platforms;
  };
})
