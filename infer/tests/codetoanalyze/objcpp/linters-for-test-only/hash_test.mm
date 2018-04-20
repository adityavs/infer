/*
 * Copyright (c) 2017 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */
#import <Foundation/NSObject.h>
#import <functional>

template <>
struct std::hash<NSObject*> {
  size_t operator()(const NSObject* const& obj1) const { return [obj1 hash]; }
};
