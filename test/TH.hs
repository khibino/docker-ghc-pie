{-# LANGUAGE TemplateHaskell #-}
-- Template Haskell が通常どおり使えること（通常ビルドの経路が壊れていないこと）の確認用。
module Main (main) where

import Language.Haskell.TH (litE, integerL)

main :: IO ()
main = print ($(litE (integerL (6 * 7))) :: Int)
