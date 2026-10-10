"""Android entrypoints must share one UI session/credential owner."""
from pathlib import Path
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
ANDROID = '{http://schemas.android.com/apk/res/android}'


class AndroidEntrypointsTest(unittest.TestCase):
    def test_external_entrypoints_reuse_launcher_session_across_tasks(self):
        manifest = ET.parse(ROOT / 'apps/raft_flutter/android/app/src/main/AndroidManifest.xml')
        application = manifest.getroot().find('application')
        activity = next(a for a in application.findall('activity')
                        if a.get(ANDROID + 'name') == '.MainActivity')
        # singleTop creates another engine when the sender is in another task;
        # that engine cannot acquire NativeSessionOwner from the first UI.
        self.assertEqual(activity.get(ANDROID + 'launchMode'), 'singleTask')
        affinity = activity.get(ANDROID + 'taskAffinity',
                                application.get(ANDROID + 'taskAffinity'))
        self.assertNotEqual(affinity, '', 'Empty affinity prevents task reuse')
        actions = {action.get(ANDROID + 'name')
                   for action in activity.findall('intent-filter/action')}
        self.assertTrue({'android.intent.action.MAIN', 'android.intent.action.VIEW',
                         'android.intent.action.SEND', 'android.intent.action.SEND_MULTIPLE'} <= actions)
        categories = {category.get(ANDROID + 'name')
                      for category in activity.findall('intent-filter/category')}
        self.assertIn('android.intent.category.LAUNCHER', categories)
        self.assertIn('android.intent.category.BROWSABLE', categories)
        # Routing of external links belongs to our authenticated coordinator.
        metadata = {m.get(ANDROID + 'name'): m.get(ANDROID + 'value')
                    for m in activity.findall('meta-data')}
        self.assertEqual(metadata['flutter_deeplinking_enabled'], 'false')


if __name__ == '__main__':
    unittest.main()
