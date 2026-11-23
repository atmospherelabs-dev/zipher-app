import 'package:flutter_test/flutter_test.dart';
import 'package:zipher/pages/accounts/restore.dart';

void main() {
  test('server failures read as a sentence, never as raw gRPC metadata', () {
    final message = restoreErrorMessage(Exception(
        'AnyhowException(get_tree_state failed: Status { code: InvalidArgument, '
        'message: "GetTreeState: z_gettreestate did not return treestate", '
        'metadata: MetadataMap { headers: {"x-backend": "sa-gru"} } })'));
    expect(message, contains('Zcash server'));
    expect(message, isNot(contains('MetadataMap')));
    expect(message, isNot(contains('sa-gru')));
  });
  test('invalid phrases and unknown failures get their own wording', () {
    expect(restoreErrorMessage(Exception('Invalid seed phrase')),
        contains('recovery phrase'));
    expect(restoreErrorMessage(StateError('something else')),
        'The restore didn’t start. Try again.');
  });
}
