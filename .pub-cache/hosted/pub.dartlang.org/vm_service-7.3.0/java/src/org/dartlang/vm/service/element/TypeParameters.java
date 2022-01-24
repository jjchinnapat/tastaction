/*
 * Copyright (c) 2015, the Dart project authors.
 *
 * Licensed under the Eclipse Public License v1.0 (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 * http://www.eclipse.org/legal/epl-v10.html
 *
 * Unless required by applicable law or agreed to in writing, software distributed under the License
 * is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express
 * or implied. See the License for the specific language governing permissions and limitations under
 * the License.
 */
package org.dartlang.vm.service.element;

// This is a generated file.

import com.google.gson.JsonObject;
import java.util.List;

/**
 * A {@link TypeParameters} object represents the type argument vector for some uninstantiated
 * generic type.
 */
@SuppressWarnings({"WeakerAccess", "unused"})
public class TypeParameters extends Element {

  public TypeParameters(JsonObject json) {
    super(json);
  }

  /**
   * The bounds set on each type parameter.
   */
  public TypeArgumentsRef getBounds() {
    return new TypeArgumentsRef((JsonObject) json.get("bounds"));
  }

  /**
   * The default types for each type parameter.
   */
  public TypeArgumentsRef getDefaults() {
    return new TypeArgumentsRef((JsonObject) json.get("defaults"));
  }

  /**
   * The names of the type parameters.
   */
  public List<String> getNames() {
    return getListString("names");
  }
}
