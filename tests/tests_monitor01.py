#!/usr/bin/env python3

# This file is part of Prozzie - The Wizzie Data Platform (WDP) main entrypoint
# Copyright (C) 2018-2019 Wizzie S.L.

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

from prozzie_pexpect import Line, test_pexpect

import pexpect
import random
import sys


if __name__ == "__main__":
    responses_sendline = {
        # Not existent volume
        'monitor custom mibs path.*:': [Line('random_volume_' +
                                             str(random.randint(0, 1000))),
                                        (pexpect.spawn.sendintr)],
        'Seconds between monitor polling': [Line('25')],
        'Topic to produce monitor metrics': [Line('monitor')],
        'Monitor agents array': [Line('')],
    }

    sys.exit(test_pexpect(sys.argv[1], responses_sendline))
