import localUnitTest from './LocalUnit.test';
import protoCodecTest from './ProtoCodec.test';

export default function testsuite() {
  localUnitTest();
  protoCodecTest();
}
